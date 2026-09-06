defmodule Omashiki.Worker.Managers do
  @moduledoc false

  alias Omashiki.Worker.State

  @type entry :: %{id: String.t(), url: String.t(), token: String.t()}

  @spec configured() :: [entry()]
  def configured do
    case Application.get_env(:omashiki, :worker_managers) do
      list when is_list(list) and list != [] ->
        list
        |> Enum.map(&normalize/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        singleton()
    end
  end

  @spec present?() :: boolean()
  def present?, do: configured() != []

  defp singleton do
    case env_singleton() do
      [] -> state_singleton()
      entries -> entries
    end
  end

  defp env_singleton do
    url = Application.get_env(:omashiki, :manager_url)
    token = Application.get_env(:omashiki, :worker_token)

    case normalize(%{url: url, token: token}) do
      nil -> []
      entry -> [entry]
    end
  end

  defp state_singleton do
    case State.load() do
      {:ok, %{manager_url: url, worker_token: token}} ->
        case normalize(%{url: url, token: token}) do
          nil -> []
          entry -> [entry]
        end

      :error ->
        []
    end
  end

  defp normalize(entry) when is_map(entry) do
    url = fetch(entry, :url)
    token = fetch(entry, :token)
    id = fetch(entry, :id)

    url =
      case url do
        u when is_binary(u) ->
          u |> String.trim() |> String.trim_trailing("/")

        _ ->
          nil
      end

    token = if is_binary(token), do: token, else: nil

    if blank?(url) or blank?(token) do
      nil
    else
      id =
        case id do
          i when is_binary(i) and i != "" -> sanitize_id(i)
          _ -> id_from_url(url)
        end

      %{id: id, url: url, token: token}
    end
  end

  defp normalize(_), do: nil

  defp fetch(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp id_from_url(url) do
    case URI.parse(url).host do
      host when is_binary(host) and host != "" -> sanitize_id(host)
      _ -> "manager"
    end
  end

  defp sanitize_id(id) do
    id
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
  end

  defp blank?(value) when value in [nil, ""], do: true
  defp blank?(_), do: false
end
