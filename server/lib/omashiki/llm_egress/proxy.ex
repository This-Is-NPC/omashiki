defmodule Omashiki.LlmEgress.Proxy do
  @moduledoc """
  Restricted HTTPS CONNECT proxy for isolated harness containers.

  The listener is intentionally separate from the supply-chain proxy. It only
  accepts CONNECT requests for exact, configured host names on port 443, and
  connects to an IP address that was checked immediately after resolution.
  """

  use GenServer

  import Bitwise

  require Logger

  alias Omashiki.Runtime.Claims

  @default_header_timeout_ms 5_000
  @default_connect_timeout_ms 5_000
  @default_relay_timeout_ms 15 * 60 * 1_000
  @default_max_header_bytes 8 * 1024
  @socket_name "llm-egress.sock"

  @doc "Start the host-side Unix socket listener."
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Return the configured socket path, or the safe per-user default.

  A Unix socket is bound to a path, so two suites that resolve to the same
  path cannot both listen: the second dies at application start with
  `:address_in_use`. `MIX_TEST_PARTITION` is folded into the default the same
  way `config/test.exs` folds it into the database name. It is unset outside
  partitioned test runs, where the path stays byte-identical to before.
  """
  def path do
    Application.get_env(:omashiki, :llm_egress_socket_path) ||
      Path.join(System.tmp_dir!(), default_socket_name())
  end

  defp default_socket_name do
    user = System.get_env("USER", "user")

    case System.get_env("MIX_TEST_PARTITION") do
      nil -> "omashiki-#{user}-#{@socket_name}"
      "" -> "omashiki-#{user}-#{@socket_name}"
      partition -> "omashiki-#{user}-#{partition}-#{@socket_name}"
    end
  end

  @doc "Return the configured exact host allowlist."
  def hosts do
    Application.get_env(:omashiki, :llm_egress_hosts, [])
  end

  @doc "Parse one complete CONNECT request, excluding any bytes after its headers."
  def parse_connect_request(request) when is_binary(request) do
    case :binary.match(request, "\r\n\r\n") do
      {index, 4} ->
        {header, _rest} = :erlang.split_binary(request, index + 4)
        parse_header_block(header)

      :nomatch ->
        {:error, :incomplete_headers}
    end
  end

  def parse_connect_request(_request), do: {:error, :bad_request}

  @doc "Resolve and authorize a hostname without opening a socket."
  def authorize_destination(host, opts \\ [])

  def authorize_destination(host, opts) when is_binary(host) do
    with {:ok, host} <- normalize_hostname(host),
         :ok <- reject_ip_literal(host),
         {:ok, allowlist} <- normalize_hosts(Keyword.get(opts, :hosts, hosts())),
         :ok <- check_allowlist(host, allowlist),
         {:ok, addresses} <- resolve(host, Keyword.get(opts, :resolver, &default_resolver/1)),
         :ok <- validate_addresses(addresses) do
      {:ok, addresses}
    end
  end

  def authorize_destination(_host, _opts), do: {:error, :bad_host}

  @doc "Authorize an isolated egress request with the job-scoped token."
  def authorize_request(token, host, opts \\ [])

  def authorize_request(token, host, opts) when is_binary(token) do
    with {:ok, _claims} <- Claims.authorize_token("egress", token),
         {:ok, addresses} <- authorize_destination(host, opts) do
      {:ok, addresses}
    end
  end

  def authorize_request(_, _, _), do: {:error, :invalid_token}

  @doc "Whether an address is private, local, link-local, multicast, or unspecified."
  def restricted_address?(address) do
    case address do
      {a, b, _c, d} when is_integer(a) and is_integer(d) ->
        a == 0 or a == 10 or a == 127 or
          (a == 100 and b in 64..127) or
          (a == 169 and b == 254) or
          (a == 172 and b in 16..31) or
          (a == 192 and b == 168) or
          a in 224..255

      {a, b, c, d, e, f, g, h}
      when is_integer(a) and is_integer(h) ->
        ipv4_mapped = a == 0 and b == 0 and c == 0 and d == 0 and e == 0 and f == 0xFFFF

        if ipv4_mapped do
          restricted_address?({div(g, 256), rem(g, 256), div(h, 256), rem(h, 256)})
        else
          (a == 0 and b == 0 and c == 0 and d == 0 and e == 0 and f == 0 and g == 0 and h == 0) or
            (a == 0 and b == 0 and c == 0 and d == 0 and e == 0 and f == 0 and g == 0 and h == 1) or
            (a &&& 0xFE00) == 0xFC00 or
            (a &&& 0xFFC0) == 0xFE80 or
            (a &&& 0xFF00) == 0xFF00
        end

      _ ->
        true
    end
  end

  @impl true
  def init(opts) do
    socket_path = Keyword.get(opts, :socket_path, path())
    dynamic_hosts? = not Keyword.has_key?(opts, :hosts)

    config = %{
      hosts: Keyword.get(opts, :hosts, hosts()),
      dynamic_hosts?: dynamic_hosts?,
      resolver: Keyword.get(opts, :resolver, &default_resolver/1),
      connector: Keyword.get(opts, :connect, Keyword.get(opts, :connector, &default_connect/3)),
      header_timeout_ms: Keyword.get(opts, :header_timeout_ms, @default_header_timeout_ms),
      connect_timeout_ms: Keyword.get(opts, :connect_timeout_ms, @default_connect_timeout_ms),
      relay_timeout_ms: Keyword.get(opts, :relay_timeout_ms, @default_relay_timeout_ms),
      max_header_bytes: Keyword.get(opts, :max_header_bytes, @default_max_header_bytes)
    }

    with true <- is_binary(socket_path) and Path.type(socket_path) == :absolute,
         {:ok, allowlist} <- normalize_hosts(config.hosts),
         :ok <- File.mkdir_p(Path.dirname(socket_path)),
         :ok <- prepare_socket(socket_path),
         {:ok, listener} <- listen(socket_path),
         :ok <- chmod_socket(listener, socket_path) do
      acceptor = spawn_link(fn -> accept_loop(listener, config) end)

      {:ok,
       %{
         listener: listener,
         acceptor: acceptor,
         path: socket_path,
         config: %{config | hosts: allowlist}
       }}
    else
      false -> {:stop, {:invalid_socket_path, socket_path}}
      {:error, reason} -> {:stop, {:llm_egress_socket, reason}}
    end
  end

  @impl true
  def terminate(_reason, %{listener: listener, path: socket_path}) do
    :gen_tcp.close(listener)
    File.rm(socket_path)
    :ok
  end

  defp listen(socket_path) do
    :gen_tcp.listen(0,
      ifaddr: {:local, String.to_charlist(socket_path)},
      mode: :binary,
      packet: :raw,
      active: false,
      reuseaddr: true
    )
  end

  defp chmod_socket(listener, socket_path) do
    case File.chmod(socket_path, 0o600) do
      :ok ->
        :ok

      {:error, reason} ->
        :gen_tcp.close(listener)
        {:error, reason}
    end
  end

  defp prepare_socket(socket_path) do
    case :gen_tcp.connect(
           {:local, String.to_charlist(socket_path)},
           0,
           [:binary, active: false],
           100
         ) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        {:error, :address_in_use}

      {:error, _reason} ->
        case File.rm(socket_path) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp accept_loop(listener, config) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        worker = spawn(fn -> receive_connection(config) end)
        :ok = :gen_tcp.controlling_process(socket, worker)
        send(worker, {:socket, socket})
        accept_loop(listener, config)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("[LlmEgress.Proxy] accept failed: #{inspect(reason)}")
        accept_loop(listener, config)
    end
  end

  defp receive_connection(config) do
    receive do
      {:socket, client} -> handle_client(client, config)
    after
      5_000 -> :ok
    end
  end

  defp handle_client(client, config) do
    case read_headers(client, config.max_header_bytes, config.header_timeout_ms) do
      {:ok, header_block, initial_data} ->
        case parse_header_block(header_block) do
          {:ok, %{host: host, port: 443, proxy_token: token}} when is_binary(token) ->
            connect_and_relay(client, host, token, initial_data, config)

          {:ok, %{port: _port}} ->
            reject(client, 400, "Bad Request")

          {:error, {status, reason}} ->
            reject(client, status, reason)
        end

      {:error, :headers_too_large} ->
        reject(client, 431, "Request Header Fields Too Large")

      {:error, :timeout} ->
        reject(client, 408, "Request Timeout")

      {:error, _reason} ->
        reject(client, 400, "Bad Request")
    end
  end

  defp connect_and_relay(client, host, token, initial_data, config) do
    authorization =
      authorize_request(token, host,
        hosts: if(config.dynamic_hosts?, do: hosts(), else: config.hosts),
        resolver: config.resolver
      )

    case authorization do
      {:ok, addresses} ->
        case connect(addresses, config.connector, config.connect_timeout_ms) do
          {:ok, upstream} ->
            case :gen_tcp.send(client, response(200, "Connection Established")) do
              :ok -> relay(client, upstream, initial_data, config.relay_timeout_ms)
              {:error, _reason} -> close_pair(client, upstream)
            end

          {:error, _reason} ->
            reject(client, 502, "Bad Gateway")
        end

      {:error, :not_allowlisted} ->
        reject(client, 403, "Forbidden")

      {:error, :restricted_destination} ->
        reject(client, 403, "Forbidden")

      {:error, :ip_literal} ->
        reject(client, 403, "Forbidden")

      {:error, _reason} ->
        reject(client, 502, "Bad Gateway")
    end
  end

  defp read_headers(socket, max_bytes, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    read_headers(socket, max_bytes, deadline, <<>>)
  end

  defp read_headers(socket, max_bytes, deadline, buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {index, 4} ->
        {header_block, rest} = :erlang.split_binary(buffer, index + 4)
        {:ok, header_block, rest}

      :nomatch when byte_size(buffer) >= max_bytes ->
        {:error, :headers_too_large}

      :nomatch ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          {:error, :timeout}
        else
          case :gen_tcp.recv(socket, 0, remaining) do
            {:ok, data} -> read_headers(socket, max_bytes, deadline, buffer <> data)
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  defp parse_header_block(header_block) do
    if String.ends_with?(header_block, "\r\n\r\n") do
      header_bytes = byte_size(header_block) - 4
      header_lines = header_block |> binary_part(0, header_bytes) |> String.split("\r\n")

      case header_lines do
        [request_line | lines] ->
          if Enum.all?(lines, &valid_header_line?/1) do
            with {:ok, request} <- parse_request_line(request_line) do
              {:ok, Map.put(request, :proxy_token, proxy_token(lines))}
            end
          else
            {:error, {400, "Bad Request"}}
          end

        _ ->
          {:error, {400, "Bad Request"}}
      end
    else
      {:error, {400, "Bad Request"}}
    end
  end

  defp proxy_token(lines) do
    lines
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, " " <> value] ->
          if String.downcase(name) == "proxy-authorization" do
            case String.split(value, " ", parts: 2) do
              ["Bearer", token] when token != "" -> token
              _ -> nil
            end
          end

        _ ->
          nil
      end
    end)
  end

  defp parse_request_line(request_line) do
    case String.split(request_line, " ", parts: 3) do
      ["CONNECT", authority, version] when version in ["HTTP/1.0", "HTTP/1.1"] ->
        case parse_authority(authority) do
          {:ok, host, port} -> {:ok, %{host: host, port: port}}
          {:error, :ip_literal} -> {:error, {403, "Forbidden"}}
          {:error, _reason} -> {:error, {400, "Bad Request"}}
        end

      [method, _authority, _version] when method != "CONNECT" ->
        {:error, {405, "Method Not Allowed"}}

      _ ->
        {:error, {400, "Bad Request"}}
    end
  end

  defp valid_header_line?(line) do
    Regex.match?(~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+:[^\r\n]*$/, line)
  end

  defp parse_authority(authority) do
    if String.starts_with?(authority, "[") or String.contains?(authority, "[") do
      {:error, :ip_literal}
    else
      case String.split(authority, ":", parts: 2) do
        [host, port] ->
          with {:ok, host} <- normalize_hostname(host),
               :ok <- reject_ip_literal(host),
               {:ok, port} <- parse_port(port) do
            {:ok, host, port}
          else
            {:error, :ip_literal} -> {:error, :ip_literal}
            error -> error
          end

        _ ->
          {:error, :bad_authority}
      end
    end
  end

  defp parse_port("443"), do: {:ok, 443}
  defp parse_port(_port), do: {:error, :bad_port}

  defp normalize_hosts(hosts) when is_list(hosts) do
    Enum.reduce_while(hosts, {:ok, MapSet.new()}, fn host, {:ok, allowlist} ->
      case normalize_hostname(host) do
        {:ok, host} -> {:cont, {:ok, MapSet.put(allowlist, host)}}
        {:error, reason} -> {:halt, {:error, {:invalid_allowlist_host, reason}}}
      end
    end)
  end

  defp normalize_hosts(%MapSet{} = hosts), do: {:ok, hosts}

  defp normalize_hosts(_hosts), do: {:error, :invalid_allowlist}

  defp normalize_hostname(host) when is_binary(host) do
    normalized = String.downcase(host)

    if byte_size(normalized) <= 253 and
         Regex.match?(
           ~r/\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/,
           normalized
         ) do
      {:ok, normalized}
    else
      {:error, :invalid_hostname}
    end
  end

  defp normalize_hostname(_host), do: {:error, :invalid_hostname}

  defp reject_ip_literal(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _address} -> {:error, :ip_literal}
      {:error, _reason} -> :ok
    end
  end

  defp check_allowlist(host, allowlist) do
    if MapSet.member?(allowlist, host), do: :ok, else: {:error, :not_allowlisted}
  end

  defp resolve(host, resolver) do
    case resolver.(host) do
      {:ok, addresses} when is_list(addresses) -> normalize_addresses(addresses)
      addresses when is_list(addresses) -> normalize_addresses(addresses)
      {:error, reason} -> {:error, {:resolution_failed, reason}}
      _ -> {:error, :resolution_failed}
    end
  end

  defp normalize_addresses(addresses) do
    addresses = Enum.uniq(addresses)

    if addresses != [] and Enum.all?(addresses, &valid_address?/1) do
      {:ok, addresses}
    else
      {:error, :resolution_failed}
    end
  end

  defp validate_addresses(addresses) do
    if Enum.any?(addresses, &restricted_address?/1),
      do: {:error, :restricted_destination},
      else: :ok
  end

  defp valid_address?({a, b, c, d}) do
    Enum.all?([a, b, c, d], &is_integer/1) and Enum.all?([a, b, c, d], &(&1 in 0..255))
  end

  defp valid_address?({a, b, c, d, e, f, g, h}) do
    Enum.all?([a, b, c, d, e, f, g, h], &is_integer/1) and
      Enum.all?([a, b, c, d, e, f, g, h], &(&1 in 0..65_535))
  end

  defp valid_address?(_address), do: false

  defp default_resolver(host) do
    results =
      Enum.map([:inet, :inet6], fn family ->
        case :inet.getaddrs(String.to_charlist(host), family) do
          {:ok, addresses} -> {:ok, addresses}
          {:error, reason} -> {:error, reason}
        end
      end)

    addresses =
      results
      |> Enum.flat_map(&if(match?({:ok, _}, &1), do: elem(&1, 1), else: []))
      |> Enum.uniq()

    if addresses == [] do
      reason =
        Enum.find_value(results, :nxdomain, fn
          {:error, reason} -> reason
          _result -> nil
        end)

      {:error, reason}
    else
      {:ok, addresses}
    end
  end

  defp connect(addresses, connector, timeout_ms) do
    Enum.reduce_while(addresses, {:error, :connect_failed}, fn address, _last_error ->
      case connector.(address, 443, timeout_ms) do
        {:ok, socket} -> {:halt, {:ok, socket}}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end)
  end

  defp default_connect(address, port, timeout_ms) do
    :gen_tcp.connect(address, port, [:binary, packet: :raw, active: false], timeout_ms)
  end

  defp relay(client, upstream, initial_data, timeout_ms) do
    with :ok <- send_initial(upstream, initial_data),
         :ok <- :inet.setopts(client, active: :once),
         :ok <- :inet.setopts(upstream, active: :once) do
      relay_loop(client, upstream, timeout_ms)
    else
      _reason -> close_pair(client, upstream)
    end
  end

  defp send_initial(_socket, <<>>), do: :ok
  defp send_initial(socket, data), do: :gen_tcp.send(socket, data)

  defp relay_loop(client, upstream, timeout_ms) do
    receive do
      {:tcp, ^client, data} -> forward(client, upstream, data, timeout_ms)
      {:tcp, ^upstream, data} -> forward(upstream, client, data, timeout_ms)
      {:tcp_closed, _socket} -> close_pair(client, upstream)
      {:tcp_error, _socket, _reason} -> close_pair(client, upstream)
    after
      timeout_ms -> close_pair(client, upstream)
    end
  end

  defp forward(source, target, data, timeout_ms) do
    case :gen_tcp.send(target, data) do
      :ok ->
        :ok = :inet.setopts(source, active: :once)
        relay_loop(source, target, timeout_ms)

      {:error, _reason} ->
        close_pair(source, target)
    end
  end

  defp reject(client, status, reason) do
    _ = :gen_tcp.send(client, response(status, reason))
    :gen_tcp.close(client)
  end

  defp response(405, reason) do
    response(405, reason, "Allow: CONNECT\r\n")
  end

  defp response(status, reason), do: response(status, reason, "")

  defp response(status, reason, extra_headers) do
    "HTTP/1.1 #{status} #{reason}\r\n" <>
      extra_headers <>
      "Content-Length: 0\r\nConnection: close\r\n\r\n"
  end

  defp close_pair(left, right) do
    :gen_tcp.close(left)
    :gen_tcp.close(right)
    :ok
  end
end
