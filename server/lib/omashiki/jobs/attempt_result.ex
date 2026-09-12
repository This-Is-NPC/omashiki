defmodule Omashiki.Jobs.AttemptResult do
  @moduledoc false

  require Logger

  alias Omashiki.Jobs.{GitArtifact, Job}

  @max_summary_bytes 4_096
  @max_change_files 1_000
  @max_path_bytes 4_096
  @max_stat 1_000_000_000

  def max_summary_bytes, do: @max_summary_bytes

  def truncate_summary(text) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" -> nil
      byte_size(text) <= @max_summary_bytes -> text
      true -> binary_prefix(text, @max_summary_bytes)
    end
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
        Logger.warning("dropping malformed job change list")
        nil
    end
  end

  def sanitize_changes(nil), do: nil

  def sanitize_changes(other) do
    Logger.warning("dropping malformed job changes: #{inspect(other)}")
    nil
  end

  def resolve_compare_url(%Job{} = job, base_sha, head_sha, _worker_url \\ nil) do
    GitArtifact.web_compare_url(admitted_remote(job), base_sha, head_sha)
  end

  defp admitted_remote(%Job{admitted_repository: %{"remote" => remote}})
       when is_binary(remote),
       do: remote

  defp admitted_remote(%Job{admitted_repository: %{remote: remote}}) when is_binary(remote),
    do: remote

  defp admitted_remote(_), do: nil

  defp binary_prefix(text, max) do
    part = binary_part(text, 0, max)

    case :unicode.characters_to_binary(part) do
      valid when is_binary(valid) -> valid
      {:incomplete, good, _rest} -> good
      {:error, good, _rest} -> good
    end
  end

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
