defmodule Omashiki.Identities.Http do
  @moduledoc false
  # Minimal blocking HTTP client for the identity broker's outbound calls.
  # Deliberately separate from `Tools.Proxy.forward/2`: the destination here is
  # operator configuration (the GitHub API), not a job-declared upstream.

  @connect_timeout_ms 10_000
  @recv_timeout_ms 30_000

  @spec request(atom(), String.t(), [{String.t(), String.t()}], String.t() | nil) ::
          {:ok, non_neg_integer(), String.t()} | {:error, term()}
  def request(method, url, headers, body) when is_atom(method) and is_binary(url) do
    uri = URI.parse(url)

    with :ok <- validate(uri),
         {:ok, conn} <-
           Mint.HTTP.connect(scheme(uri), uri.host, port(uri),
             mode: :passive,
             transport_opts: [timeout: @connect_timeout_ms]
           ),
         {:ok, conn, ref} <-
           Mint.HTTP.request(conn, verb(method), path(uri), headers, body || "") do
      receive_all(conn, ref, "", nil)
    end
  end

  defp validate(%URI{scheme: scheme, host: host})
       when scheme in ["http", "https"] and is_binary(host) and host != "",
       do: :ok

  defp validate(_), do: {:error, :invalid_url}

  defp scheme(%URI{scheme: "https"}), do: :https
  defp scheme(_), do: :http

  defp port(%URI{port: port}) when is_integer(port), do: port
  defp port(%URI{scheme: "https"}), do: 443
  defp port(_), do: 80

  defp path(%URI{path: path, query: nil}), do: path || "/"
  defp path(%URI{path: path, query: query}), do: (path || "/") <> "?" <> query

  defp verb(method), do: method |> Atom.to_string() |> String.upcase()

  defp receive_all(conn, ref, body, status) do
    case Mint.HTTP.recv(conn, 0, @recv_timeout_ms) do
      {:ok, conn, responses} ->
        {body, status, done?} =
          Enum.reduce(responses, {body, status, false}, fn
            {:status, ^ref, value}, {b, _, d} -> {b, value, d}
            {:data, ^ref, chunk}, {b, s, d} -> {b <> chunk, s, d}
            {:done, ^ref}, {b, s, _} -> {b, s, true}
            _, acc -> acc
          end)

        if done? do
          Mint.HTTP.close(conn)
          {:ok, status, body}
        else
          receive_all(conn, ref, body, status)
        end

      {:error, conn, reason, _} ->
        Mint.HTTP.close(conn)
        {:error, reason}
    end
  end
end
