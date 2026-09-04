defmodule Omashiki.Worker.Slots do
  @moduledoc false

  use GenServer

  alias Omashiki.HostSettings

  def start_link(opts \\ []) do
    max =
      case Keyword.get(opts, :max) do
        n when is_integer(n) and n > 0 -> n
        _ -> HostSettings.get_max_concurrent_containers()
      end

    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, max, name: name)
  end

  @spec try_acquire(GenServer.server()) :: :ok | {:error, :full}
  def try_acquire(server \\ __MODULE__) do
    GenServer.call(server, :try_acquire)
  end

  @spec release(GenServer.server()) :: :ok
  def release(server \\ __MODULE__) do
    GenServer.call(server, :release)
  end

  @spec available(GenServer.server()) :: non_neg_integer()
  def available(server \\ __MODULE__) do
    GenServer.call(server, :available)
  end

  @spec snapshot(GenServer.server()) :: %{
          max: pos_integer(),
          used: non_neg_integer(),
          free: non_neg_integer()
        }
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @impl true
  def init(max) when is_integer(max) and max > 0 do
    {:ok, {max, 0}}
  end

  @impl true
  def handle_call(:try_acquire, _from, {max, used}) when used >= max do
    {:reply, {:error, :full}, {max, used}}
  end

  def handle_call(:try_acquire, _from, {max, used}) do
    {:reply, :ok, {max, used + 1}}
  end

  def handle_call(:release, _from, {max, 0}) do
    {:reply, :ok, {max, 0}}
  end

  def handle_call(:release, _from, {max, used}) do
    {:reply, :ok, {max, used - 1}}
  end

  def handle_call(:available, _from, {max, used}) do
    {:reply, max - used, {max, used}}
  end

  def handle_call(:snapshot, _from, {max, used} = state) do
    {:reply, %{max: max, used: used, free: max - used}, state}
  end
end
