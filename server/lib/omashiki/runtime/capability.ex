defmodule Omashiki.Runtime.Capability do
  @moduledoc "Runtime-only operations exposed to plugins."

  @type endpoint :: %{host: String.t(), port: pos_integer()}
  @type exec_result :: %{stdout: String.t(), exit_code: non_neg_integer() | nil}
  @type exec_fun :: ([String.t()], pos_integer() -> {:ok, exec_result()} | {:error, term()})
  @enforce_keys [:transport, :endpoint, :exec]
  defstruct [:transport, :endpoint, :exec]

  @type t :: %__MODULE__{
          transport: :http | :cli,
          endpoint: endpoint() | nil,
          exec: exec_fun()
        }

  @doc "Build a capability from a provisioned sandbox and its injected boundary."
  @spec from_sandbox(map(), module()) :: t()
  def from_sandbox(sandbox, boundary) when is_map(sandbox) and is_atom(boundary) do
    transport =
      normalize_transport(Map.get(sandbox, :transport, Map.get(sandbox, "transport")))

    endpoint = endpoint_from(sandbox)

    %__MODULE__{
      transport: transport,
      endpoint: endpoint,
      exec: fn argv, timeout_ms -> boundary.exec(sandbox, argv, timeout_ms) end
    }
  end

  @spec exec(t(), [String.t()], pos_integer()) :: {:ok, exec_result()} | {:error, term()}
  def exec(%__MODULE__{exec: fun}, argv, timeout_ms)
      when is_function(fun, 2) and is_list(argv) and is_integer(timeout_ms) and timeout_ms > 0 do
    fun.(argv, timeout_ms)
  end

  @spec endpoint(t()) :: {:ok, endpoint()} | {:error, :http_endpoint_unavailable}
  def endpoint(%__MODULE__{transport: :http, endpoint: %{host: host, port: port}})
      when is_binary(host) and is_integer(port) and port > 0,
      do: {:ok, %{host: host, port: port}}

  def endpoint(%__MODULE__{}), do: {:error, :http_endpoint_unavailable}

  defp endpoint_from(%{host: host, port: port}) when is_binary(host) and is_integer(port),
    do: %{host: host, port: port}

  defp endpoint_from(%{"host" => host, "port" => port})
       when is_binary(host) and is_integer(port),
       do: %{host: host, port: port}

  defp endpoint_from(_), do: nil

  defp normalize_transport(%{kind: kind}), do: normalize_transport(kind)
  defp normalize_transport(%{"kind" => kind}), do: normalize_transport(kind)
  defp normalize_transport(:http), do: :http
  defp normalize_transport("http"), do: :http
  defp normalize_transport(:cli), do: :cli
  defp normalize_transport("cli"), do: :cli
  defp normalize_transport(_), do: :cli
end
