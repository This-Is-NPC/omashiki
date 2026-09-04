defmodule Omashiki.Worker.DataPlane do
  @moduledoc false

  @spec base_url() :: String.t() | nil
  def base_url, do: base_url(nil)

  @spec base_url(nil | String.t()) :: String.t() | nil
  def base_url(nil) do
    case Application.get_env(:omashiki, :manager_url) do
      url when is_binary(url) ->
        trimmed = String.trim(url)

        if trimmed == "" do
          nil
        else
          String.trim_trailing(trimmed, "/")
        end

      _ ->
        nil
    end
  end

  def base_url(url) when is_binary(url) do
    trimmed = String.trim(url)

    if trimmed == "" do
      nil
    else
      String.trim_trailing(trimmed, "/")
    end
  end

  @spec remote?(nil | String.t()) :: boolean()
  def remote?(url \\ nil) do
    case url do
      url when is_binary(url) -> is_binary(base_url(url))
      _ -> is_binary(base_url())
    end
  end
end
