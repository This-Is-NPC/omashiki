defmodule Omashiki.Jobs.Validate do
  @moduledoc """
  Universal VALIDATE stage: symlink, size, protected path, secret scan.

  PROVISION and PUBLISH vary by sink. VALIDATE does not. Call this before
  any publish path; never collect artifact metadata without it.

  The protected directories `.git/`, `.ssh/` and `.aws/` are refused by path:
  output never writes there, whatever the content. Every other file is judged
  by its content, through `Omashiki.Jobs.SecretScan`. When the scanner is
  unavailable the output is refused.

  `:secret_scan` is required: the job's `Omashiki.Jobs.SecretScan.Policy`,
  whose allowed findings are dropped, or `:skip` for output an operator
  approved after the scan refused it.
  """

  alias Omashiki.Jobs.SecretScan
  alias Omashiki.Jobs.SecretScan.Policy

  @max_bytes 100 * 1024 * 1024

  @protected_dirs [".git/", ".ssh/", ".aws/"]

  @doc "Reject output that must not be published."
  def scan(path, paths, changed_bytes, opts \\ []) when is_binary(path) and is_list(paths) do
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)

    cond do
      symlink = Enum.find(paths, &symlink_path?(path, &1)) ->
        {:error, {:symlink_path, symlink}}

      changed_bytes > max_bytes ->
        {:error, {:oversized_output, changed_bytes, max_bytes}}

      protected = Enum.find(paths, &protected_path?/1) ->
        {:error, {:protected_path, protected}}

      true ->
        secret_scan(path, paths, Keyword.fetch!(opts, :secret_scan))
    end
  end

  defp secret_scan(_path, _paths, :skip), do: :ok

  defp secret_scan(path, paths, %Policy{} = policy) do
    case SecretScan.scan(path, paths, policy.key) do
      {:ok, findings} ->
        case Enum.reject(findings, &Policy.allowed?(policy, &1.fingerprint)) do
          [] -> :ok
          refused -> {:error, {:secret_found, refused}}
        end

      {:error, reason} ->
        {:error, {:secret_scan_unavailable, reason}}
    end
  end

  defp protected_path?(path) do
    path
    |> String.trim_leading("./")
    |> String.downcase()
    |> String.starts_with?(@protected_dirs)
  end

  defp symlink_path?(path, relative) do
    case File.lstat(Path.expand(Path.join(path, relative))) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _ -> false
    end
  end
end
