defmodule Omashiki.Doctor.Monitor do
  @moduledoc """
  Keeps the latest `Omashiki.Doctor` report for the System screen.

  The full doctor, route check included, runs once in the background after
  boot, and only its warnings and errors are logged. The cheap checks then run
  again every `:doctor_interval_ms`; the route result from boot is kept, since
  starting a container on a timer is not cheap. Nothing here can block or fail
  the boot: every run happens in a task, and a crashed run leaves the previous
  report in place.
  """

  use GenServer

  require Logger

  alias Omashiki.Doctor

  @default_interval_ms 60_000

  @doc """
  Options: `:name`, `:boot` (run the full doctor now; default `:doctor_on_boot`),
  `:interval_ms`, and `:doctor`, extra options for `Omashiki.Doctor.run/1`.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "`%{checks: [check], checked_at: DateTime.t() | nil}`; empty before the first run."
  def latest(server \\ __MODULE__) do
    GenServer.call(server, :latest)
  catch
    :exit, _ -> %{checks: [], checked_at: nil}
  end

  @doc "Re-run the cheap checks now and return the updated report."
  def refresh(server \\ __MODULE__, timeout \\ 30_000) do
    GenServer.call(server, :refresh, timeout)
  end

  @impl true
  def init(opts) do
    state = %{
      checks: [],
      checked_at: nil,
      doctor: Keyword.get(opts, :doctor, []),
      interval_ms:
        Keyword.get_lazy(opts, :interval_ms, fn ->
          Application.get_env(:omashiki, :doctor_interval_ms, @default_interval_ms)
        end),
      task: nil,
      timer: nil,
      waiting: []
    }

    boot? = Keyword.get(opts, :boot, Application.get_env(:omashiki, :doctor_on_boot, true))
    if boot?, do: {:ok, start_run(state, true)}, else: {:ok, state}
  end

  @impl true
  def handle_call(:latest, _from, state),
    do: {:reply, Map.take(state, [:checks, :checked_at]), state}

  def handle_call(:refresh, from, state) do
    state = if state.task, do: state, else: start_run(state, false)
    {:noreply, %{state | waiting: [from | state.waiting]}}
  end

  @impl true
  def handle_info(:refresh, %{task: nil} = state), do: {:noreply, start_run(state, false)}
  def handle_info(:refresh, state), do: {:noreply, state}

  def handle_info({ref, {route?, checks}}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    if route?, do: log(checks)

    checks = if route?, do: checks, else: keep_routes(checks, state.checks)
    state = %{state | checks: checks, checked_at: DateTime.utc_now(), task: nil}
    {:noreply, finish(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.warning("[Doctor] run failed: #{inspect(reason)}")
    {:noreply, finish(%{state | task: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_run(state, route?) do
    opts = Keyword.put(state.doctor, :route, route?)

    task =
      Task.Supervisor.async_nolink(Omashiki.Runtime.TaskSupervisor, fn ->
        {route?, Doctor.run(opts)}
      end)

    %{state | task: task}
  end

  defp finish(state) do
    Enum.each(state.waiting, &GenServer.reply(&1, Map.take(state, [:checks, :checked_at])))
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | waiting: [], timer: Process.send_after(self(), :refresh, state.interval_ms)}
  end

  # A cheap run has no route checks; carry the last ones over while Docker
  # still answers, since a route result says nothing once Docker is gone.
  defp keep_routes(checks, previous) do
    if Enum.any?(checks, &match?(%{id: "docker", status: :ok}, &1)),
      do: checks ++ Enum.filter(previous, &String.starts_with?(&1.id, "route:")),
      else: checks
  end

  defp log(checks) do
    for %{status: status} = check <- checks, status != :ok do
      level = if status == :error, do: :error, else: :warning
      Logger.log(level, "[Doctor] #{check.summary} Fix: #{check.fix}")
    end

    :ok
  end
end
