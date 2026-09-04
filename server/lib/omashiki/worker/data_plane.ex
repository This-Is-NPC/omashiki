defmodule Omashiki.Worker.DataPlane do
  @moduledoc false

  @spec base_url() :: String.t() | nil
  def base_url do
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

  @spec remote?() :: boolean()
  def remote?, do: is_binary(base_url())
end
