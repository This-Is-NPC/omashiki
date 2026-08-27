defmodule Omashiki.Jobs.Validate do
  @moduledoc """
  Universal VALIDATE stage: secret scan, symlink, protected path, 100 MiB.

  PROVISION and PUBLISH vary by sink. VALIDATE does not. Call this before
  any publish path; never collect artifact metadata without it.
  """

  @max_bytes 100 * 1024 * 1024

  @secret_re ~r/(?:-----BEGIN .*PRIVATE KEY-----|(?:api[_-]?key|secret|password|token)\s*[:=]\s*\S+|(?:AKIA|ASIA)[A-Z0-9]{16}|gh[pousr]_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]{12,})/i

  def max_bytes, do: @max_bytes

  @doc "Reject output that must not be published."
  def scan(path, paths, changed_bytes, opts \\ []) when is_binary(path) and is_list(paths) do
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)
    protected_paths = Keyword.get(opts, :protected_paths, [])
    protected = Enum.find(paths, &protected_path?(&1, protected_paths))
    symlink = Enum.find(paths, &symlink_path?(path, &1))

    cond do
      symlink ->
        {:error, {:symlink_path, symlink}}

      changed_bytes > max_bytes ->
        {:error, {:oversized_output, changed_bytes, max_bytes}}

      protected ->
        {:error, {:protected_path, protected}}

      Enum.any?(paths, &contains_secret?(path, &1)) ->
        {:error, {:likely_secret, Enum.find(paths, &contains_secret?(path, &1))}}

      true ->
        :ok
    end
  end

  def contained?(path, root), do: String.starts_with?(path, root <> "/") or path == root

  defp protected_path?(path, configured) do
    protected_path?(path) or
      Enum.any?(configured, fn prefix ->
        is_binary(prefix) and
          (path == prefix or String.starts_with?(path, String.trim_trailing(prefix, "/") <> "/"))
      end)
  end

  defp protected_path?(path) do
    normalized = String.downcase(String.trim_leading(path, "./"))
    base = Path.basename(normalized)

    String.starts_with?(normalized, [".git/", ".ssh/", ".aws/"]) or
      base in [".env", ".npmrc", ".pypirc", "id_rsa", "id_ed25519"] or
      String.contains?(base, ["secret", "credential", "password", "token"]) or
      String.ends_with?(base, [".pem", ".key", ".p12", ".pfx"])
  end

  defp contains_secret?(path, relative) do
    absolute = Path.expand(Path.join(path, relative))

    case File.lstat(absolute) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.read(absolute) do
          {:ok, content} -> String.valid?(content) and Regex.match?(@secret_re, content)
          _ -> false
        end

      _ ->
        false
    end
  end

  defp symlink_path?(path, relative) do
    case File.lstat(Path.expand(Path.join(path, relative))) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _ -> false
    end
  end
end
