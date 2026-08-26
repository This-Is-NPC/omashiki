defmodule Omashiki.Config.Rollout do
  @moduledoc """
  Applies a configuration change to a running core, in one of two modes.

  Swapping a model — or any `[environments.*]` value — is a hot operation. The
  core does not restart; `Omashiki.Config.reload/1` re-reads `omashiki.toml`,
  re-resolves every `${env:VAR}` against the environment as it stands *now*,
  and replaces the live generation. Which is why the reload is the thing that
  applies a model swap rather than a redeploy.

  ## The two modes, from `[reload].mode`

    * `:gradual` (default) — swap the live generation immediately. Newly
      admitted jobs resolve against it; attempts already running finish on the
      generation captured in their own `jobs` row. The rollout is complete when
      the last attempt admitted under a prior digest terminates, which is the
      percentage `Runtime.Inspector` publishes.

    * `:drain_all` — close admission, wait for every active attempt to
      terminate, then swap, then reopen. The whole fleet crosses the boundary
      at once and no two containers ever run different generations.

  Gradual is the default because it costs nothing: the snapshot capture at
  admission already makes a mixed fleet correct, so waiting buys uniformity and
  pays for it in queueing. `:drain_all` is for the case where uniformity is the
  point — comparing two models on the same workload, or retiring a provider.

  ## The drain bound

  `[reload].drain_timeout_ms` bounds the wait. When it expires with attempts
  still running, the drain is **abandoned**: admission reopens and the previous
  generation keeps serving. Nothing is applied and nothing is cancelled.

  That is deliberate. The alternative — killing a user's job so an operator's
  config change can land — is a product decision this module is not entitled to
  make, and a half-drained swap is exactly the "partially applied" state the
  operator asked to be able to *see* rather than to suffer silently. An
  operator who wants the change through a long-running attempt has `:gradual`,
  which applies immediately and lets the attempt finish on what it was admitted
  with.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Omashiki.Config
  alias Omashiki.Jobs.JobAttempt
  alias Omashiki.Repo

  @topic "config:rollout"
  @poll_ms 1_000

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    server_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @doc "PubSub topic carrying `{:config_rollout, status}` on every state change."
  def topic, do: @topic

  @doc """
  Apply the declared file to the running core.

  Returns `{:ok, info}` when the swap landed, `{:ok, :draining}` when
  `:drain_all` accepted the request and is waiting for attempts to finish, or
  `{:error, reason}`. A failed parse leaves the previous generation serving.

  Never blocks for the length of a drain. A drain can legitimately take as long
  as the longest attempt, and holding the operator's click open for that is how
  a page ends up looking hung during the very operation it is meant to show.
  Progress arrives on `topic/0` and in `status/0` instead.
  """
  def reload(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:reload, opts}, Keyword.get(opts, :timeout, 15_000))
  end

  @doc """
  False only while a `:drain_all` rollout is waiting for attempts to finish.

  `Jobs.Admission` consults this, so the pause is a closed door at the front of
  the system rather than work that queues up behind a swap.
  """
  def admission_open?(server \\ __MODULE__) do
    GenServer.call(server, :admission_open?)
  catch
    :exit, _ -> true
  end

  @doc "Current mode, drain state and last outcome. Never raises."
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _ -> idle_status(Config.reload_policy())
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       path: Keyword.get(opts, :path),
       poll_ms:
         Keyword.get_lazy(opts, :poll_ms, fn ->
           Application.get_env(:omashiki, :rollout_poll_ms, @poll_ms)
         end),
       counter: Keyword.get(opts, :counter, :configured),
       drain: nil,
       last: nil
     }}
  end

  @impl true
  def handle_call(:admission_open?, _from, state), do: {:reply, is_nil(state.drain), state}

  def handle_call(:status, _from, state), do: {:reply, status_of(state), state}

  def handle_call({:reload, opts}, _from, state) do
    mode = Keyword.get(opts, :mode) || Config.reload_policy().mode

    cond do
      state.drain != nil ->
        {:reply, {:error, :drain_in_progress}, state}

      mode == :drain_all ->
        {:reply, {:ok, :draining}, start_drain(state, opts)}

      true ->
        {result, state} = swap(state, opts)
        {:reply, result, state}
    end
  end

  @impl true
  def handle_info(:drain_tick, %{drain: nil} = state), do: {:noreply, state}

  def handle_info(:drain_tick, %{drain: drain} = state) do
    remaining = active_attempts(state)

    cond do
      remaining == 0 ->
        {_result, state} = swap(%{state | drain: nil}, drain.opts)
        {:noreply, state}

      System.monotonic_time(:millisecond) >= drain.deadline ->
        Logger.warning(
          "[Config.Rollout] drain timed out after #{drain.timeout_ms}ms with " <>
            "#{remaining} attempt(s) still running; configuration unchanged"
        )

        state = %{state | drain: nil, last: {:error, :drain_timeout}}
        broadcast(state)
        {:noreply, state}

      true ->
        schedule(state.poll_ms)
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- internals -------------------------------------------------------------

  defp start_drain(state, opts) do
    timeout_ms = Keyword.get(opts, :drain_timeout_ms) || Config.reload_policy().drain_timeout_ms

    drain = %{
      opts: opts,
      started_at: DateTime.utc_now(),
      timeout_ms: timeout_ms,
      deadline: System.monotonic_time(:millisecond) + timeout_ms,
      waiting_for: active_attempts(state)
    }

    state = %{state | drain: drain}
    broadcast(state)

    # Immediate tick: an idle host must not sit through a poll interval with
    # admission closed for nothing.
    send(self(), :drain_tick)
    state
  end

  defp swap(state, opts) do
    result = Config.reload(path(state, opts))
    state = %{state | last: result}
    broadcast(state)

    case result do
      {:ok, info} ->
        Logger.info(
          "[Config.Rollout] generation #{info.generation} applied " <>
            "(digest #{String.slice(info.digest || "", 0, 12)}, changed=#{info.changed?})"
        )

      {:error, reason} ->
        Logger.error(
          "[Config.Rollout] reload rejected, previous generation still serving: #{reason}"
        )
    end

    {result, state}
  end

  # Same precedence the rest of the app uses for an injectable source: explicit
  # argument, then how this server was started, then application environment,
  # then the repo-root default.
  defp path(state, opts) do
    Keyword.get(opts, :path) || state.path ||
      Application.get_env(:omashiki, :config_path) || Config.default_path()
  end

  defp schedule(poll_ms), do: Process.send_after(self(), :drain_tick, poll_ms)

  defp status_of(%{drain: nil} = state) do
    Config.reload_policy() |> idle_status() |> Map.put(:last, state.last)
  end

  defp status_of(%{drain: drain} = state) do
    Config.reload_policy()
    |> idle_status()
    |> Map.merge(%{
      draining?: true,
      drain_started_at: drain.started_at,
      drain_timeout_ms: drain.timeout_ms,
      waiting_for: active_attempts(state),
      last: state.last
    })
  end

  defp idle_status(policy) do
    %{
      mode: policy.mode,
      draining?: false,
      drain_started_at: nil,
      drain_timeout_ms: policy.drain_timeout_ms,
      waiting_for: 0,
      last: nil
    }
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(Omashiki.PubSub, @topic, {:config_rollout, status_of(state)})
  catch
    _, _ -> :ok
  end

  # Resolved per tick rather than captured, mirroring `Runtime.Inspector`'s
  # census hook: tests drive the drain without a database, production counts
  # rows.
  defp active_attempts(%{counter: :configured}) do
    Application.get_env(
      :omashiki,
      :rollout_attempt_counter,
      {__MODULE__, :count_active_attempts, []}
    )
    |> apply_counter()
  end

  defp active_attempts(%{counter: counter}), do: apply_counter(counter)

  defp apply_counter({module, function, args}), do: apply(module, function, args)
  defp apply_counter(fun) when is_function(fun, 0), do: fun.()

  @doc false
  def count_active_attempts do
    Repo.aggregate(
      from(attempt in JobAttempt, where: attempt.status in ["provisioning", "running"]),
      :count
    )
  rescue
    _ -> 0
  end
end
