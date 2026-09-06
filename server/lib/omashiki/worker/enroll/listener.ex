defmodule Omashiki.Worker.Enroll.Listener do
  @moduledoc false

  use GenServer

  require Logger

  alias Omashiki.Worker.Enroll

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Return the TCP port the enroll listener bound."
  @spec port(GenServer.server()) :: pos_integer()
  def port(server \\ __MODULE__) do
    GenServer.call(server, :port)
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, Enroll.port())
    ip = Keyword.get(opts, :ip, :any)

    children = [
      {Bandit, plug: {Omashiki.Worker.Enroll.Plug, []}, port: port, ip: ip}
    ]

    case Supervisor.start_link(children, strategy: :one_for_one) do
      {:ok, supervisor} ->
        {:ok, %{supervisor: supervisor, port: port}}

      {:error, reason} = error ->
        Logger.error("Worker.Enroll.Listener failed to start on port #{port}: #{inspect(reason)}")
        error
    end
  end

  @impl true
  def handle_call(:port, _from, %{port: port} = state) do
    {:reply, port, state}
  end
end
