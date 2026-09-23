defmodule Omashiki.Jobs.SecretScan do
  @moduledoc """
  Scans job output for secrets with gitleaks and its default rule set.

  Only the files handed to `scan/2` are scanned, never Git history. They are
  copied into a private staging directory first, so gitleaks sees nothing
  else: no `.gitleaks.toml` or `.gitleaksignore` the agent wrote, and no
  `GITLEAKS_CONFIG` from the house environment. `gitleaks:allow` comments are
  ignored for the same reason.

  gitleaks never prints a secret: its report is rendered through a template
  that replaces the secret in the match with `REDACTED` and keeps only the
  secret's SHA-256.

  The executable is `gitleaks` in `PATH`; the `:gitleaks_cli` application
  setting names another.
  """

  defmodule Finding do
    @moduledoc """
    One secret gitleaks found.

    `file` is relative to the scanned root and `match` has the secret replaced
    with `REDACTED`. `fingerprint` is the lowercase hex SHA-256 of the file,
    the rule, and the secret's SHA-256: it stays the same when the same secret
    is found in the same file again, wherever the line moves.
    """

    @enforce_keys [:file, :line, :rule_id, :description, :match, :fingerprint]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            file: String.t(),
            line: pos_integer(),
            rule_id: String.t(),
            description: String.t(),
            match: String.t(),
            fingerprint: String.t()
          }
  end

  @timeout_ms 120_000
  # Distinct from 1, which gitleaks uses for its own errors.
  @leaks_exit 3

  @template """
  {{- range . }}
  {{ toJson (dict "file" .File "line" .StartLine "rule_id" .RuleID "description" .Description "match" (.Match | replace .Secret "REDACTED") "secret_sha256" (sha256sum .Secret)) }}
  {{- end }}
  """

  @doc """
  Scan the regular files among `paths`, relative to `root`.

  Paths that are not regular files inside `root` are skipped. Returns
  `{:error, reason}` when gitleaks is missing, fails, or times out.
  """
  @spec scan(String.t(), [String.t()]) :: {:ok, [Finding.t()]} | {:error, term()}
  def scan(root, paths) do
    root = Path.expand(root)

    case Enum.filter(paths, &regular?(root, &1)) do
      [] -> {:ok, []}
      files -> in_workspace(&scan_files(&1, root, files))
    end
  end

  @doc "The version gitleaks reports, proving it is installed and runs."
  @spec version() :: {:ok, String.t()} | {:error, term()}
  def version do
    case run(["version"]) do
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      {:ok, {output, status}} -> {:error, {:exit, status, excerpt(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp scan_files(workspace, root, files) do
    # gitleaks reads its configuration from the root of the scanned directory,
    # so the output sits one level below it.
    target = Path.join(workspace, "target")
    stage = Path.join(target, "output")
    template = Path.join(workspace, "report.tmpl")
    report = Path.join(workspace, "report.jsonl")

    Enum.each(files, fn relative ->
      destination = Path.expand(relative, stage)
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(Path.expand(relative, root), destination)
    end)

    File.write!(template, @template)

    args = [
      "dir",
      target,
      "--no-banner",
      "--log-level=error",
      "--ignore-gitleaks-allow",
      "--gitleaks-ignore-path=#{workspace}",
      "--report-format=template",
      "--report-template=#{template}",
      "--report-path=#{report}",
      "--exit-code=#{@leaks_exit}",
      "--timeout=#{div(@timeout_ms, 1000)}"
    ]

    case run(args) do
      {:ok, {_output, status}} when status in [0, @leaks_exit] -> findings(report, stage)
      {:ok, {output, status}} -> {:error, {:exit, status, excerpt(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp findings(report, stage) do
    report
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, raw} -> {:cont, {:ok, [finding(raw, stage) | acc]}}
        {:error, _error} -> {:halt, {:error, :unreadable_report}}
      end
    end)
    |> case do
      {:ok, findings} -> {:ok, Enum.sort_by(findings, &{&1.file, &1.line, &1.rule_id})}
      error -> error
    end
  end

  defp finding(raw, stage) do
    file = Path.relative_to(raw["file"], stage)
    rule_id = raw["rule_id"]

    %Finding{
      file: file,
      line: raw["line"],
      rule_id: rule_id,
      description: raw["description"],
      match: raw["match"],
      fingerprint:
        :sha256
        |> :crypto.hash([file, 0, rule_id, 0, raw["secret_sha256"]])
        |> Base.encode16(case: :lower)
    }
  end

  defp run(args) do
    case System.find_executable(cli()) do
      nil ->
        {:error, :not_found}

      executable ->
        task =
          Task.async(fn ->
            System.cmd(executable, args,
              stderr_to_stdout: true,
              env: [{"GITLEAKS_CONFIG", nil}, {"GITLEAKS_CONFIG_TOML", nil}]
            )
          end)

        case Task.yield(task, @timeout_ms + 5_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> {:ok, result}
          nil -> {:error, :timeout}
        end
    end
  end

  # A fresh private directory per scan, removed afterwards.
  defp in_workspace(fun) do
    name = "omashiki-secret-scan-" <> Base.url_encode64(:crypto.strong_rand_bytes(12))
    workspace = Path.join(System.tmp_dir!(), name)

    try do
      File.mkdir!(workspace)
      File.chmod!(workspace, 0o700)
      fun.(workspace)
    rescue
      error in File.Error -> {:error, {:staging_failed, error.reason}}
    after
      File.rm_rf(workspace)
    end
  end

  defp regular?(root, relative) do
    absolute = Path.expand(relative, root)

    String.starts_with?(absolute, root <> "/") and
      match?({:ok, %File.Stat{type: :regular}}, File.lstat(absolute))
  end

  defp excerpt(output), do: output |> String.trim() |> String.slice(0, 512)

  defp cli, do: Application.get_env(:omashiki, :gitleaks_cli, "gitleaks")
end
