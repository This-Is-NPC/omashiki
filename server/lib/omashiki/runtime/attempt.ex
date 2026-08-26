defmodule Omashiki.Runtime.Attempt do
  @moduledoc "Coordinates one running attempt while durable state remains in PostgreSQL."

  use GenServer, restart: :temporary

  alias Omashiki.Jobs.JobAttempt
  alias Omashiki.Runtime.AttemptSupervisor

  @heartbeat_interval_ms 10_000

  def start_link({%JobAttempt{} = attempt, opts}) do
    GenServer.start_link(__MODULE__, {attempt, opts}, name: via(attempt.id))
  end

  def child_spec(arg) do
    %{
      id: {__MODULE__, elem(arg, 0).id},
      start: {__MODULE__, :start_link, [arg]},
      restart: :temporary
    }
  end

  def await(server, timeout \\ :infinity), do: GenServer.call(server, :await, timeout)
  def cancel(server), do: GenServer.cast(server, :cancel)

  @impl true
  def init({%JobAttempt{} = attempt, opts}) do
    interval = Keyword.get(opts, :heartbeat_interval_ms, @heartbeat_interval_ms)

    state = %{
      attempt: attempt,
      opts: opts,
      task: nil,
      waiters: [],
      result: nil,
      cancelling: false,
      started_at: System.monotonic_time(:millisecond),
      heartbeat_interval_ms: interval,
      heartbeat_timer: nil
    }

    Omashiki.Runtime.LeaseRenewer.register(attempt.id, attempt.lease_token)

    {:ok, state, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    task =
      Task.Supervisor.async_nolink(Omashiki.Runtime.TaskSupervisor, fn ->
        runner_module(state.opts).run(state.attempt, Keyword.put(state.opts, :heartbeat, false))
      end)

    {:noreply, %{state | task: task}}
  end

  @impl true
  def handle_call(:await, from, %{result: nil} = state) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(:await, _from, %{result: result} = state), do: {:reply, result, state}

  @impl true
  def handle_cast(:cancel, state) do
    if not state.cancelling do
      scope_id = "job-#{state.attempt.id}"

      _ =
        Task.Supervisor.start_child(Omashiki.Runtime.TaskSupervisor, fn ->
          cancel_runtime(state, scope_id)
        end)

      emit(:cancel, %{count: 1}, state, "requested")
    end

    {:noreply, %{state | cancelling: true}}
  end

  # The batch renewer owns the lease now; losing it means this attempt was
  # fenced, finished, or expired elsewhere, and the runtime must stop.
  @impl true
  def handle_info({:lease_lost, _attempt_id}, %{result: nil} = state) do
    emit(:heartbeat, %{count: 1}, state, "lease_lost")
    handle_cast(:cancel, %{state | cancelling: false})
  end

  def handle_info({:lease_lost, _attempt_id}, state), do: {:noreply, state}

  @impl true
  def handle_info(:heartbeat, %{result: nil} = state) do
    state = %{state | heartbeat_timer: nil}

    case Omashiki.Jobs.heartbeat(state.attempt, state.attempt.lease_token) do
      {:ok, attempt} ->
        {:noreply, schedule_heartbeat(%{state | attempt: attempt})}

      {:error, reason} ->
        handle_cast(:cancel, %{state | cancelling: false})
        |> then(fn {:noreply, next} -> {:noreply, next} end)
        |> tap(fn _ -> emit(:heartbeat, %{count: 1}, state, inspect(reason)) end)
    end
  end

  def handle_info(:heartbeat, state), do: {:noreply, %{state | heartbeat_timer: nil}}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    finish(result, %{state | task: nil})
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    _ = cancel_runtime(state, "job-#{state.attempt.id}")
    _ = AttemptSupervisor.fail_if_active(state.attempt, reason)
    finish({:error, {:runner_task_exit, reason}}, %{state | task: nil})
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.heartbeat_timer)

    if state.result == nil do
      _ = cancel_runtime(state, "job-#{state.attempt.id}")
    end

    :ok
  end

  defp finish(result, state) do
    cancel_timer(state.heartbeat_timer)
    Enum.each(state.waiters, &GenServer.reply(&1, result))

    emit(
      :complete,
      %{duration_ms: max(System.monotonic_time(:millisecond) - state.started_at, 0)},
      state,
      outcome(result)
    )

    Omashiki.Runtime.LeaseRenewer.unregister(state.attempt.id)

    {:stop, :normal, %{state | result: result, waiters: [], heartbeat_timer: nil}}
  end

  defp runner_module(opts),
    do: Keyword.get(opts, :runner, Application.get_env(:omashiki, :jobs_runner, Omashiki.Jobs.Runner))

  defp schedule_heartbeat(%{heartbeat_interval_ms: interval} = state)
       when is_integer(interval) and interval > 0 do
    %{state | heartbeat_timer: Process.send_after(self(), :heartbeat, interval)}
  end

  defp schedule_heartbeat(state), do: state

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: true, info: false)

  defp via(attempt_id),
    do: {:via, Registry, {Omashiki.Runtime.AttemptRegistry, {:attempt, attempt_id}}}

  defp outcome({:ok, _}), do: "ok"
  defp outcome(_), do: "error"

  defp cancel_runtime(state, scope_id) do
    container =
      Keyword.get(
        state.opts,
        :container,
        Omashiki.Jobs.Runner.DockerContainer
      )

    if function_exported?(container, :cancel_scope, 1) do
      container.cancel_scope(scope_id)
    else
      Omashiki.Runtime.ContainerManager.cancel_scope(scope_id)
    end
  end

  defp emit(event, measurements, state, outcome) do
    :telemetry.execute(
      [:omashiki, :runtime, :attempt, event],
      measurements,
      %{attempt_id: state.attempt.id, outcome: outcome}
    )
  end
end
