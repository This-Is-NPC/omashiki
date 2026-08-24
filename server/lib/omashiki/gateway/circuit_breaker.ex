defmodule Omashiki.Gateway.CircuitBreaker do
  @moduledoc """
  Per-credential circuit breaker for the LLM gateway.

  After `:failure_threshold` consecutive failures the circuit opens for
  `:open_ms` milliseconds. Success resets the failure count.
  """

  use GenServer

  @failure_threshold 3
  @open_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def allow?(credential_id) when is_binary(credential_id) do
    GenServer.call(__MODULE__, {:allow, credential_id})
  end

  @doc """
  Read-only circuit state for UI. Returns `:closed` | `:open` | `:half_open`.

  Unlike `allow?/1`, this never transitions half-open — paint must not
  probe the breaker.
  """
  def state(credential_id) when is_binary(credential_id) do
    GenServer.call(__MODULE__, {:state, credential_id})
  end

  def record_success(credential_id) when is_binary(credential_id) do
    GenServer.cast(__MODULE__, {:success, credential_id})
  end

  def record_failure(credential_id) when is_binary(credential_id) do
    GenServer.cast(__MODULE__, {:failure, credential_id})
  end

  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def init(_opts) do
    {:ok, %{circuits: %{}}}
  end

  @impl true
  def handle_call({:allow, id}, _from, state) do
    now = System.monotonic_time(:millisecond)

    case Map.get(state.circuits, id) do
      %{state: :open, opened_at: t} when now - t < @open_ms ->
        {:reply, :open, state}

      %{state: :open} ->
        # Half-open: allow one probe.
        circuits = put_in(state.circuits[id], %{state: :half_open, failures: 0, opened_at: nil})
        {:reply, :ok, %{state | circuits: circuits}}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:state, id}, _from, state) do
    status =
      case Map.get(state.circuits, id) do
        %{state: s} -> s
        _ -> :closed
      end

    {:reply, status, state}
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{circuits: %{}}}

  @impl true
  def handle_cast({:success, id}, state) do
    {:noreply, %{state | circuits: Map.delete(state.circuits, id)}}
  end

  def handle_cast({:failure, id}, state) do
    entry = Map.get(state.circuits, id, %{state: :closed, failures: 0, opened_at: nil})
    failures = entry.failures + 1

    entry =
      if failures >= @failure_threshold do
        %{state: :open, failures: failures, opened_at: System.monotonic_time(:millisecond)}
      else
        %{entry | failures: failures, state: :closed}
      end

    {:noreply, %{state | circuits: Map.put(state.circuits, id, entry)}}
  end
end
