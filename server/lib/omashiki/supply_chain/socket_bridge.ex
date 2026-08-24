defmodule Omashiki.SupplyChain.SocketBridge do
  @moduledoc """
  Exposes the Phoenix HTTP listener to isolated agent containers through a
  Unix socket. The container-side relay can reach this socket without joining
  any network that has host or Internet egress.
  """

  use GenServer

  require Logger

  @socket_name "supply-chain.sock"
  @idle_timeout_ms 15 * 60 * 1_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Host path bind-mounted into allowlisted agent containers."
  def path do
    Application.get_env(:omashiki, :supply_chain_socket_path) ||
      Path.join(System.tmp_dir!(), "omashiki-#{System.get_env("USER", "user")}-#{@socket_name}")
  end

  @impl true
  def init(_opts) do
    socket_path = path()

    with :ok <- File.mkdir_p(Path.dirname(socket_path)),
         :ok <- prepare_socket(socket_path),
         {:ok, listener} <-
           :gen_tcp.listen(0,
             ifaddr: {:local, String.to_charlist(socket_path)},
             mode: :binary,
             packet: :raw,
             active: false,
             reuseaddr: true
           ),
         :ok <- File.chmod(socket_path, 0o600) do
      acceptor = spawn_link(fn -> accept_loop(listener) end)
      {:ok, %{listener: listener, acceptor: acceptor, path: socket_path}}
    else
      {:error, reason} -> {:stop, {:supply_chain_socket, reason}}
    end
  end

  defp prepare_socket(path) do
    case :gen_tcp.connect(
           {:local, String.to_charlist(path)},
           0,
           [:binary, active: false],
           100
         ) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        {:error, :address_in_use}

      {:error, _reason} ->
        case File.rm(path) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def terminate(_reason, %{listener: listener, path: path}) do
    :gen_tcp.close(listener)
    File.rm(path)
    :ok
  end

  defp accept_loop(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        pid = spawn(fn -> receive_connection() end)
        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, {:socket, socket})
        accept_loop(listener)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("[SupplyChain.SocketBridge] accept failed: #{inspect(reason)}")
        accept_loop(listener)
    end
  end

  defp receive_connection do
    receive do
      {:socket, client} -> bridge(client)
    after
      5_000 -> :ok
    end
  end

  defp bridge(client) do
    port = endpoint_port()

    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :raw, active: false], 5_000) do
      {:ok, upstream} ->
        :ok = :inet.setopts(client, active: :once)
        :ok = :inet.setopts(upstream, active: :once)
        relay(client, upstream)

      {:error, reason} ->
        Logger.warning("[SupplyChain.SocketBridge] endpoint connect failed: #{inspect(reason)}")
        :gen_tcp.close(client)
    end
  end

  defp relay(left, right) do
    receive do
      {:tcp, ^left, data} -> forward(left, right, data, left, right)
      {:tcp, ^right, data} -> forward(right, left, data, left, right)
      {:tcp_closed, _socket} -> close_pair(left, right)
      {:tcp_error, _socket, _reason} -> close_pair(left, right)
    after
      @idle_timeout_ms -> close_pair(left, right)
    end
  end

  defp forward(source, target, data, left, right) do
    case :gen_tcp.send(target, data) do
      :ok ->
        :ok = :inet.setopts(source, active: :once)
        relay(left, right)

      {:error, _reason} ->
        close_pair(left, right)
    end
  end

  defp close_pair(left, right) do
    :gen_tcp.close(left)
    :gen_tcp.close(right)
    :ok
  end

  defp endpoint_port do
    :omashiki
    |> Application.fetch_env!(OmashikiWeb.Endpoint)
    |> Keyword.fetch!(:http)
    |> Keyword.fetch!(:port)
  end
end
