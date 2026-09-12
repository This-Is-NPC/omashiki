defmodule Omashiki.Jobs.AttemptResult do
  @moduledoc false

  alias Omashiki.Jobs.{GitArtifact, Job, Statuses}

  @max_change_files 1_000
  @max_path_bytes 4_096
  @max_compare_url_bytes 2_048
  @max_stat 1_000_000_000

  def truncate_summary(text) when is_binary(text) do
    text |> String.trim() |> String.slice(0, Statuses.max_summary_bytes())
  end

  def truncate_summary(_), do: nil

  def sanitize_changes(map) when is_map(map) do
    files = Map.get(map, "files") || Map.get(map, :files)

    case sanitize_file_list(files) do
      {:ok, files} ->
        %{
          "files_changed" => length(files),
          "insertions" => Enum.reduce(files, 0, &(&1["insertions"] + &2)),
          "deletions" => Enum.reduce(files, 0, &(&1["deletions"] + &2)),
          "files" => files
        }

      :error ->
        nil
    end
  end

  def sanitize_changes(_), do: nil

  def sanitize_compare_url(url)
      when is_binary(url) and byte_size(url) <= @max_compare_url_bytes do
    uri = URI.parse(url)

    if uri.scheme == "https" and is_nil(uri.userinfo) and
         uri.host in ["github.com", "gitlab.com"] and
         is_binary(uri.path) and String.contains?(uri.path, "/compare/") do
      url
    else
      nil
    end
  end

  def sanitize_compare_url(_), do: nil

  def resolve_compare_url(%Job{} = job, base_sha, head_sha, worker_url) do
    GitArtifact.web_compare_url(admitted_remote(job), base_sha, head_sha) ||
      sanitize_compare_url(worker_url)
  end

  defp admitted_remote(%Job{admitted_repository: %{"remote" => remote}})
       when is_binary(remote),
       do: remote

  defp admitted_remote(%Job{admitted_repository: %{remote: remote}}) when is_binary(remote),
    do: remote

  defp admitted_remote(_), do: nil

  defp sanitize_file_list(files) when is_list(files) and length(files) <= @max_change_files do
    files
    |> Enum.reduce_while([], fn entry, acc ->
      case sanitize_file(entry) do
        nil -> {:halt, :error}
        file -> {:cont, [file | acc]}
      end
    end)
    |> case do
      :error -> :error
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp sanitize_file_list(_), do: :error

  defp sanitize_file(entry) when is_map(entry) do
    path = Map.get(entry, "path") || Map.get(entry, :path)
    insertions = Map.get(entry, "insertions") || Map.get(entry, :insertions)
    deletions = Map.get(entry, "deletions") || Map.get(entry, :deletions)

    if valid_path?(path) and valid_stat?(insertions) and valid_stat?(deletions) do
      %{
        "path" => path,
        "insertions" => insertions,
        "deletions" => deletions
      }
    end
  end

  defp sanitize_file(_), do: nil

  defp valid_path?(path)
       when is_binary(path) and path != "" and byte_size(path) <= @max_path_bytes do
    String.valid?(path) and not String.contains?(path, <<0>>)
  end

  defp valid_path?(_), do: false

  defp valid_stat?(n) when is_integer(n) and n >= 0 and n <= @max_stat, do: true
  defp valid_stat?(_), do: false
end
