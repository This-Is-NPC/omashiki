defmodule Omashiki.Runtime.Inspector do
  @moduledoc """
  One cached census of the runtime, joined across the three places that each
  hold a third of the truth.

    * **Processes** — the attempt registry. One entry per live `Runtime.Attempt`
      coordinator under its DynamicSupervisor.
    * **Containers** — the runtime port's `census/0`. What this host is actually
      running, whether or not anything owns it.
    * **Attempts** — `job_attempts`, which knows the job, the status and the
      `node_id` that claimed it.

  Each source read alone looks healthy during the failure this exists to catch.
  Joined on the attempt id, the disagreements become the diagnosis: a container
  with no owning process is abandoned, a process with no container is either
  provisioning or hung before it got one, and an attempt row that this node
  claims but has neither of is the wedge.

  ## Why this is a poller and not a query per render

  The container half is an HTTP request to the Docker daemon. A LiveView that
  fetched it on every render would issue one request per operator per refresh,
  and the screen an operator opens *because* the system is struggling would add
  load to the struggling part. So:

    * exactly one census per `:interval_ms`, no matter how many people are
      watching;
    * nothing at all when nobody is watching — the timer keeps ticking, the
      request is not made;
    * `snapshot/0` is a cached read that never reaches the port;
    * the census runs in a task, so a daemon that has stopped answering leaves
      this process responsive and the page showing its last known state with an
      honest age, rather than hanging alongside everything else.

  ## The configuration rollout rides on the same poll

  Each active attempt carries, on its `jobs` row, the `registry_digest` it was
  admitted under. Compared to the live digest that is a per-container answer to
  "which configuration is this actually running?", and in aggregate it is the
  applied percentage of a hot reload — see `config_state/2`.

  It is computed here rather than anywhere else for one reason: this poll
  already has the attempt rows and the container list joined. A separate
  watcher for the rollout would be a second timer and, worse, a second reader
  of the Docker daemon for a question the first reader already answered.
  """

  use GenServer

  import Ecto.Query

  alias Omashiki.Config
  alias Omashiki.Config.Rollout
  alias Omashiki.Jobs.Job
  alias Omashiki.Jobs.JobAttempt
  alias Omashiki.Repo
  alias Omashiki.Runtime.AttemptSupervisor
  alias Omashiki.Runtime.ContainerManager
  alias Omashiki.Runtime.LeaseRenewer

  @topic "runtime:inspector"
  @interval_ms 3_000
  @registry Omashiki.Runtime.AttemptRegistry

  @link_order [
    :orphan_container,
    :process_without_container,
    :attempt_without_process,
    :linked,
    :remote
  ]

  @type link ::
          :linked
          | :orphan_container
          | :process_without_container
          | :attempt_without_process
          | :remote

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    server_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @doc "PubSub topic carrying `{:runtime_snapshot, snapshot}` after each poll."
  def topic, do: @topic

  @doc """
  Register `pid` as a watcher and subscribe the caller to `topic/0`.

  Polling is demand-driven: with no watchers the census is never taken. Watchers
  are monitored, so a LiveView that goes away stops the polling it caused.
  """
  def watch(server \\ __MODULE__, pid \\ nil) do
    watcher = pid || self()
    Phoenix.PubSub.subscribe(Omashiki.PubSub, @topic)
    GenServer.cast(server, {:watch, watcher})
  end

  @doc "The last snapshot taken. Never reaches the runtime port."
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @doc """
  Take a census now and return the resulting snapshot.

  Callers that arrive while one is already in flight wait for that one rather
  than starting a second, so a burst of operators opening the page at once
  costs a single request.
  """
  def refresh(server \\ __MODULE__, timeout \\ 15_000) do
    GenServer.call(server, :refresh, timeout)
  end

  @doc false
  def empty_census, do: {:ok, []}

  @impl true
  def init(opts) do
    interval = Keyword.get_lazy(opts, :interval_ms, &configured_interval_ms/0)
    schedule(interval)

    {:ok,
     %{
       snapshot: empty_snapshot(),
       watchers: %{},
       waiters: [],
       task: nil,
       interval_ms: interval,
       census: Keyword.get(opts, :census, :configured)
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}

  def handle_call(:refresh, from, state) do
    {:noreply, state |> add_waiter(from) |> ensure_polling()}
  end

  @impl true
  def handle_cast({:watch, pid}, state) do
    if Map.has_key?(state.watchers, pid) do
      {:noreply, state}
    else
      ref = Process.monitor(pid)
      {:noreply, %{state | watchers: Map.put(state.watchers, pid, ref)}}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    schedule(state.interval_ms)

    if map_size(state.watchers) == 0 do
      {:noreply, state}
    else
      {:noreply, ensure_polling(state)}
    end
  end

  def handle_info({ref, snapshot}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Enum.each(state.waiters, &GenServer.reply(&1, snapshot))
    Phoenix.PubSub.broadcast(Omashiki.PubSub, @topic, {:runtime_snapshot, snapshot})

    {:noreply, %{state | task: nil, waiters: [], snapshot: snapshot}}
  end

  # A census that crashed must not leave a caller blocked: reply with the last
  # snapshot, whose `taken_at` already says how stale it is.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %Task{ref: ref}} = state) do
    Enum.each(state.waiters, &GenServer.reply(&1, state.snapshot))
    {:noreply, %{state | task: nil, waiters: []}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.watchers, pid) do
      ^ref -> {:noreply, %{state | watchers: Map.delete(state.watchers, pid)}}
      _ -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp add_waiter(state, from), do: %{state | waiters: [from | state.waiters]}

  defp ensure_polling(%{task: nil} = state) do
    census = state.census

    task =
      Task.Supervisor.async_nolink(Omashiki.Runtime.TaskSupervisor, fn -> build(census) end)

    %{state | task: task}
  end

  defp ensure_polling(state), do: state

  defp schedule(interval) when is_integer(interval) and interval > 0,
    do: Process.send_after(self(), :tick, interval)

  defp schedule(_interval), do: :ok

  # Resolved per poll rather than captured at init, so the source is whatever it
  # is at the moment the census is taken. Overridable so tests can drive the
  # join without a Docker daemon; production reads the runtime port.
  defp configured_census do
    Application.get_env(:omashiki, :runtime_census, {ContainerManager, :census, []})
  end

  defp configured_interval_ms do
    Application.get_env(:omashiki, :runtime_inspector_interval_ms, @interval_ms)
  end

  # -- snapshot --------------------------------------------------------------

  @doc false
  def build(:configured), do: build(configured_census())

  def build(census) do
    node_id = current_node_id()
    live_digest = live_digest()

    {containers, runtime} =
      case take_census(census) do
        {:ok, entries} -> {entries, :ok}
        {:error, reason} -> {[], {:error, reason}}
      end

    rows = correlate(containers, active_attempts(), attempt_processes(), node_id, live_digest)

    %{
      node_id: node_id,
      taken_at: DateTime.utc_now(),
      runtime: runtime,
      supervised: supervised_count(),
      lease_renewer_alive?: alive?(LeaseRenewer),
      dispatch_executing: dispatch_executing(),
      rows: rows,
      counts: counts(rows),
      config: config_state(rows, live_digest)
    }
  end

  defp empty_snapshot do
    %{
      node_id: nil,
      taken_at: nil,
      runtime: :never_polled,
      supervised: 0,
      lease_renewer_alive?: false,
      dispatch_executing: 0,
      rows: [],
      counts: counts([]),
      config: config_state([], nil)
    }
  end

  defp take_census({module, function, args}), do: apply(module, function, args)
  defp take_census(fun) when is_function(fun, 0), do: fun.()

  # -- the join --------------------------------------------------------------

  @doc """
  Join containers, attempt rows and live processes on the attempt id.

  Pure, and public so the classification can be tested without a daemon, a
  database or a supervision tree. `containers` are `census/0` entries,
  `attempts` are maps with `:id`, `:job_id`, `:status`, `:node_id` and
  `:started_at`, and `processes` are `{attempt_id, pid}` pairs.
  """
  @spec correlate([map()], [map()], [{String.t(), pid()}], String.t() | nil, String.t() | nil) ::
          [map()]
  def correlate(containers, attempts, processes, node_id, live_digest \\ nil) do
    by_process = Map.new(processes)
    by_attempt = Map.new(attempts, &{&1.id, &1})

    # An unlabelled container gets a key of its own rather than sharing `nil`
    # with every other unlabelled container: eighty-four of them collapsing into
    # one row would hide the scale of exactly the problem worth seeing.
    by_container =
      Enum.group_by(containers, fn entry ->
        case attempt_id_from_scope(entry.scope_id) do
          nil -> {:unlabelled, entry.id}
          attempt_id -> attempt_id
        end
      end)

    (Map.keys(by_attempt) ++ Map.keys(by_process) ++ Map.keys(by_container))
    |> Enum.uniq()
    |> Enum.map(&row(&1, by_attempt, by_process, by_container, node_id, live_digest))
    |> Enum.sort_by(&{link_rank(&1.link), &1.attempt_id || "", &1.key_label})
  end

  @doc "Tally of `correlate/4` rows by link state, with every state present."
  @spec counts([map()]) :: %{link() => non_neg_integer()}
  def counts(rows) do
    tallied = Enum.frequencies_by(rows, & &1.link)
    Map.new(@link_order, &{&1, Map.get(tallied, &1, 0)})
  end

  defp row(key, by_attempt, by_process, by_container, node_id, live_digest) do
    attempt = Map.get(by_attempt, key)
    pid = Map.get(by_process, key)
    containers = Map.get(by_container, key, [])
    attempt_id = if is_binary(key), do: key, else: nil

    %{
      key_label: key_label(key),
      attempt_id: attempt_id,
      job_id: attempt && attempt.job_id,
      status: attempt && attempt.status,
      node_id: (attempt && attempt.node_id) || implicit_node(pid, containers, node_id),
      pid: pid,
      containers: containers,
      started_at: attempt && attempt.started_at,
      link: link(attempt, pid, containers, node_id),
      registry_digest: attempt && Map.get(attempt, :registry_digest),
      generation: generation(attempt, live_digest)
    }
  end

  # Which configuration generation this row's work is running against.
  #
  # The digest was captured on the `jobs` row at admission and, until this,
  # never read back — it was provenance and nothing else. Comparing it to the
  # live one is what turns "the operator changed the model" into a number:
  # `:current` rows are already on the new generation, `:prior` rows are the
  # ones the rollout is still waiting for. `:unknown` is a container or process
  # with no attempt row behind it — an orphan has no generation to be on.
  defp generation(nil, _live_digest), do: :unknown
  defp generation(_attempt, live_digest) when not is_binary(live_digest), do: :unknown

  defp generation(attempt, live_digest) do
    case Map.get(attempt, :registry_digest) do
      ^live_digest -> :current
      digest when is_binary(digest) -> :prior
      _ -> :unknown
    end
  end

  # A process or a container observed here is on this machine by definition,
  # even when no row claims it.
  defp implicit_node(nil, [], _node_id), do: nil
  defp implicit_node(_pid, _containers, node_id), do: node_id

  defp link(attempt, pid, containers, node_id) do
    cond do
      pid != nil and containers != [] -> :linked
      pid != nil -> :process_without_container
      containers != [] -> :orphan_container
      attempt != nil and attempt.node_id not in [nil, node_id] -> :remote
      true -> :attempt_without_process
    end
  end

  defp link_rank(link), do: Enum.find_index(@link_order, &(&1 == link)) || length(@link_order)

  defp key_label({:unlabelled, container_id}), do: container_id
  defp key_label(attempt_id) when is_binary(attempt_id), do: attempt_id

  defp attempt_id_from_scope("job-" <> attempt_id) when attempt_id != "", do: attempt_id
  defp attempt_id_from_scope(_scope_id), do: nil

  # -- sources ---------------------------------------------------------------

  # Joined to `jobs` for the one column that makes the rollout percentage
  # computable: the registry digest the job was admitted under. It lives on the
  # job, not the attempt — a retry of a job admitted three generations ago is
  # still owed that generation's configuration.
  defp active_attempts do
    Repo.all(
      from(attempt in JobAttempt,
        join: job in Job,
        on: job.id == attempt.job_id,
        where: attempt.status in ["provisioning", "running"],
        select: %{
          id: attempt.id,
          job_id: attempt.job_id,
          status: attempt.status,
          node_id: attempt.node_id,
          started_at: attempt.started_at,
          registry_digest: job.registry_digest
        }
      )
    )
  rescue
    _ -> []
  end

  # -- configuration rollout -------------------------------------------------

  @doc """
  Applied percentage and generation tally for `rows` against `live_digest`.

  Applied % is active attempts on the live digest over all active attempts. An
  idle host is 100%: nothing is running against a superseded generation, so
  there is nothing left to roll out.
  """
  @spec config_state([map()], String.t() | nil) :: map()
  def config_state(rows, live_digest) do
    tallied = Enum.frequencies_by(rows, & &1.generation)
    current = Map.get(tallied, :current, 0)
    prior = Map.get(tallied, :prior, 0)
    total = current + prior

    %{
      digest: live_digest,
      generation: config_generation(),
      loaded_at: config_loaded_at(),
      current: current,
      prior: prior,
      total: total,
      applied_percent: applied_percent(current, total),
      rollout: rollout_status()
    }
  end

  defp applied_percent(_current, 0), do: 100
  defp applied_percent(current, total), do: round(current * 100 / total)

  defp live_digest do
    Config.current_digest()
  rescue
    _ -> nil
  end

  defp config_generation do
    Config.generation()
  rescue
    _ -> 0
  end

  defp config_loaded_at do
    Config.loaded_at()
  rescue
    _ -> nil
  end

  defp rollout_status do
    Rollout.status()
  rescue
    _ -> %{mode: :gradual, draining?: false, drain_timeout_ms: 0, waiting_for: 0, last: nil}
  end

  defp attempt_processes do
    Registry.select(@registry, [
      {{{:attempt, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
  rescue
    _ -> []
  end

  defp supervised_count do
    DynamicSupervisor.count_children(AttemptSupervisor).active
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end

  # The number that was missing during the wedge: sixty-five Oban workers
  # believed they were executing while zero attempts were active. Reading it
  # next to the attempt count is what makes that contradiction visible.
  defp dispatch_executing do
    Repo.one(from(job in "oban_jobs", where: job.state == "executing", select: count(job.id))) ||
      0
  rescue
    _ -> 0
  end

  defp alive?(name) do
    case Process.whereis(name) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp current_node_id do
    Omashiki.Config.current_node().name
  rescue
    _ -> nil
  end
end
