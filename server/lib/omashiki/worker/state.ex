defmodule Omashiki.Worker.State do
  @moduledoc false

  @type t :: %{
          manager_url: String.t(),
          worker_token: String.t()
        }

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

  @doc "Persist enrollment and apply it to runtime configuration."
  @spec save(t()) :: :ok | :error
  def save(%{} = state) do
    with {:ok, normalized} <- normalize(state),
         :ok <- ensure_dir!(),
         :ok <-
           File.write(
             path(),
             Jason.encode!(Map.take(normalized, [:manager_url, :worker_token]))
           ),
         :ok <- File.chmod(path(), 0o600) do
      apply(normalized)
      :ok
    else
      _ -> :error
    end
  end

  @doc "Apply enrollment to `Application` env without writing the file."
  @spec apply(t()) :: :ok | :error
  def apply(%{} = state) do
    case normalize(state) do
      {:ok, %{manager_url: url, worker_token: token}} ->
        Application.put_env(:omashiki, :manager_url, url)
        Application.put_env(:omashiki, :worker_token, token)
        :ok

      :error ->
        :error
    end
  end

  @doc "Restore persisted enrollment on worker boot."
  @spec restore!() :: :ok
  def restore! do
    case load() do
      {:ok, state} ->
        :ok = apply(state)
        :ok

      :error ->
        :ok
    end
  end

  @doc "Remove persisted enrollment."
  @spec clear() :: :ok
  def clear do
    _ = File.rm(path())
    Application.delete_env(:omashiki, :manager_url)
    Application.delete_env(:omashiki, :worker_token)
    :ok
  end

  defp normalize(%{"manager_url" => url, "worker_token" => token}),
    do: normalize(%{manager_url: url, worker_token: token})

  defp normalize(%{manager_url: url, worker_token: token})
       when is_binary(url) and is_binary(token) do
    url = url |> String.trim() |> String.trim_trailing("/")
    token = String.trim(token)

    if url == "" or token == "" or not valid_url?(url) do
      :error
    else
      {:ok, %{manager_url: url, worker_token: token}}
    end
  end

  defp normalize(_), do: :error

  defp valid_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp ensure_dir! do
    path() |> Path.dirname() |> File.mkdir_p!()
    :ok
  end
end
