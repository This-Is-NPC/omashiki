defmodule Omashiki.Worker.State do
  @moduledoc """
  Persisted enrollment: which houses this machine serves.

  One worker can be lent to many houses. Each enrollment is one manager entry
  — an id, a base URL and the worker token that house issued — stored on
  disk with mode 0600 and read back by `Omashiki.Worker.Managers` whenever
  the poller is (re)configured. Enrolling the same id again replaces that
  entry; removing an id stops polling that house without touching the rest.

  The pre-list file shape (`manager_url` + `worker_token`) still loads as a
  single entry so an already-enrolled worker keeps working after upgrade.
  """

  @type entry :: %{id: String.t(), url: String.t(), token: String.t()}
  @type t :: %{managers: [entry()]}

  @doc "Resolved on-disk enrollment path."
  @spec path() :: String.t()
  def path do
    case Application.get_env(:omashiki, :worker_state_path) do
      path when is_binary(path) and path != "" ->
        Path.expand(path)

      _ ->
        Path.join(System.user_home!(), ".cache/omashiki/worker-state.json")
    end
  end

  @doc "Load persisted enrollment, if any."
  @spec load() :: {:ok, t()} | :error
  def load do
    file = path()

    with true <- File.exists?(file),
         {:ok, raw} <- File.read(file),
         {:ok, decoded} <- Jason.decode(raw),
         {:ok, state} <- normalize(decoded) do
      {:ok, state}
    else
      _ -> :error
    end
  end

  @doc "Persisted entries, or `[]` when nothing is enrolled."
  @spec managers() :: [entry()]
  def managers do
    case load() do
      {:ok, %{managers: managers}} -> managers
      :error -> []
    end
  end

  @doc "Replace the whole enrollment. Accepts the list shape or one legacy entry."
  @spec save(map()) :: :ok | :error
  def save(%{} = state) do
    with {:ok, normalized} <- normalize(state), do: write(normalized)
  end

  @doc "Add or replace one house by id."
  @spec enroll(map()) :: {:ok, [entry()]} | :error
  def enroll(%{} = params) do
    with {:ok, entry} <- normalize_entry(params) do
      merged =
        managers()
        |> Enum.reject(&(&1.id == entry.id))
        |> Kernel.++([entry])

      case write(%{managers: merged}) do
        :ok -> {:ok, merged}
        :error -> :error
      end
    end
  end

  @doc "Forget one house by id. Unknown ids are a no-op."
  @spec remove(String.t()) :: {:ok, [entry()]} | :error
  def remove(id) when is_binary(id) do
    remaining = Enum.reject(managers(), &(&1.id == id))

    case write(%{managers: remaining}) do
      :ok -> {:ok, remaining}
      :error -> :error
    end
  end

  @doc "Validate what is on disk at boot. Never raises; an unreadable file is empty."
  @spec restore!() :: :ok
  def restore! do
    _ = load()
    :ok
  end

  @doc "Remove persisted enrollment."
  @spec clear() :: :ok
  def clear do
    _ = File.rm(path())
    :ok
  end

  defp write(%{managers: managers}) do
    encoded =
      Jason.encode!(%{
        "managers" => Enum.map(managers, &%{"id" => &1.id, "url" => &1.url, "token" => &1.token})
      })

    with :ok <- ensure_dir(),
         :ok <- File.write(path(), encoded),
         :ok <- File.chmod(path(), 0o600) do
      :ok
    else
      _ -> :error
    end
  end

  defp normalize(%{"managers" => list}) when is_list(list), do: normalize(%{managers: list})

  defp normalize(%{managers: list}) when is_list(list) do
    entries = Enum.map(list, &normalize_entry/1)

    if Enum.any?(entries, &(&1 == :error)) do
      :error
    else
      entries = Enum.map(entries, fn {:ok, entry} -> entry end)
      ids = Enum.map(entries, & &1.id)

      if ids == Enum.uniq(ids), do: {:ok, %{managers: entries}}, else: :error
    end
  end

  # Legacy single-house file, and the single-house `save/1` argument.
  defp normalize(%{"manager_url" => url, "worker_token" => token}),
    do: normalize(%{manager_url: url, worker_token: token})

  defp normalize(%{manager_url: url, worker_token: token}) do
    with {:ok, entry} <- normalize_entry(%{url: url, token: token}) do
      {:ok, %{managers: [entry]}}
    end
  end

  defp normalize(_), do: :error

  defp normalize_entry(%{} = params) do
    url = fetch(params, :url) || fetch(params, :manager_url)
    token = fetch(params, :token) || fetch(params, :worker_token)
    id = fetch(params, :id) || fetch(params, :manager_id)

    with url when is_binary(url) <- url,
         token when is_binary(token) <- token do
      url = url |> String.trim() |> String.trim_trailing("/")
      token = String.trim(token)

      cond do
        url == "" or token == "" or not valid_url?(url) -> :error
        true -> {:ok, %{id: id_for(id, url), url: url, token: token}}
      end
    else
      _ -> :error
    end
  end

  defp normalize_entry(_), do: :error

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp id_for(id, url) do
    case id do
      given when is_binary(given) and given != "" -> sanitize_id(given)
      _ -> url |> URI.parse() |> Map.get(:host) |> Kernel.||("manager") |> sanitize_id()
    end
  end

  defp sanitize_id(id), do: id |> String.trim() |> String.replace(~r/[^A-Za-z0-9._-]/, "-")

  defp valid_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp ensure_dir do
    path() |> Path.dirname() |> File.mkdir_p()
  end
end
