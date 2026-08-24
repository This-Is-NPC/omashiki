defmodule OmashikiWeb.LoggerFilter do
  @moduledoc """
  Logger filter that scrubs `Authorization:` header values and
  `?token=` query parameters from request log metadata before they
  reach any backend.

  Installed by `Application.start/2` via
  `:logger.add_primary_filter/2`.
  """

  @doc """
  `:logger` filter callback. Returns the (possibly mutated) log event
  or `:ignore` if the event should be dropped (we never drop, just
  scrub).
  """
  def filter(%{meta: meta} = event, _opts) when is_map(meta) do
    new_meta =
      meta
      |> scrub_conn()
      |> scrub_metadata_string(:request_path)
      |> scrub_metadata_string(:query_string)

    %{event | meta: new_meta}
  end

  def filter(event, _opts), do: event

  defp scrub_conn(%{conn: %Plug.Conn{} = conn} = meta) do
    %{meta | conn: scrub_plug_conn(conn)}
  end

  defp scrub_conn(meta), do: meta

  defp scrub_plug_conn(
         %Plug.Conn{req_headers: headers, query_string: qs, request_path: path} = conn
       ) do
    %{
      conn
      | req_headers: scrub_headers(headers),
        query_string: scrub_query_string(qs),
        request_path: scrub_secrets(path)
    }
  end

  defp scrub_headers(headers) when is_list(headers) do
    Enum.map(headers, fn
      {"authorization", _} -> {"authorization", "[REDACTED]"}
      {"Authorization", _} -> {"Authorization", "[REDACTED]"}
      other -> other
    end)
  end

  defp scrub_headers(other), do: other

  defp scrub_query_string(qs) when is_binary(qs), do: scrub_token_param(qs)
  defp scrub_query_string(other), do: other

  defp scrub_metadata_string(meta, key) do
    case Map.get(meta, key) do
      s when is_binary(s) -> Map.put(meta, key, scrub_secrets(s))
      _ -> meta
    end
  end

  defp scrub_token_param(s) when is_binary(s) do
    Regex.replace(~r/(\?|&)token=[^&\s]+/, s, "\\1token=[REDACTED]")
  end

  defp scrub_secrets(s) when is_binary(s) do
    s
    |> scrub_token_param()
    |> then(&Regex.replace(~r{(/api/v1/supply-chain/[^/]+/[^/]+/)[^/\s]+}, &1, "\\1[REDACTED]"))
  end
end
