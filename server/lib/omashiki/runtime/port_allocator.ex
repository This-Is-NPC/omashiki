defmodule Omashiki.Runtime.PortAllocator do
  @moduledoc "Atomically leases localhost ports to concurrent HTTP runtimes."

  use GenServer

  @first 14_096
  @last 14_999

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def reserve(scope_id), do: GenServer.call(__MODULE__, {:reserve, scope_id})
  def release(scope_id), do: GenServer.call(__MODULE__, {:release, scope_id})

  @impl true
  def init(opts) do
    {:ok, %{range: Keyword.get(opts, :range, @first..@last), leases: %{}}}
  end

  @impl true
  def handle_call({:reserve, scope_id}, _from, state) do
    case Map.fetch(state.leases, scope_id) do
      {:ok, port} ->
        {:reply, {:ok, port}, state}

      :error ->
        leased = state.leases |> Map.values() |> MapSet.new()

        case Enum.find(state.range, &(not MapSet.member?(leased, &1) and listenable?(&1))) do
          nil -> {:reply, {:error, :host_port_range_exhausted}, state}
          port -> {:reply, {:ok, port}, put_in(state, [:leases, scope_id], port)}
        end
    end
  end

  def handle_call({:release, scope_id}, _from, state) do
    {:reply, :ok, %{state | leases: Map.delete(state.leases, scope_id)}}
  end

  defp listenable?(port) do
    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end
end
