defmodule Omashiki.Jobs.GitArtifactTest do
  use ExUnit.Case, async: false

  alias Omashiki.Jobs.{GitArtifact, Job}

  setup do
    root =
      Path.join(System.tmp_dir!(), "omashiki-git-artifact-#{System.unique_integer([:positive])}")

    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["commit", "--allow-empty", "-q", "-m", "init"], identity_env())

    job = %Job{
      id: "job-#{System.unique_integer([:positive])}",
      current_attempt: 2,
      repository_snapshot: %{"path" => repo, "base_branch" => "main"}
    }

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, job: job, repo: repo}
  end

  test "captures base SHA and creates an isolated job worktree", %{job: job, repo: repo} do
    assert {:ok, artifact} = GitArtifact.provision_worktree(job)
    assert artifact.branch == "omashiki/job-#{job.id}"
    assert artifact.base_sha == git!(repo, ["rev-parse", "main"])
    assert File.dir?(artifact.path)

    assert :ok = GitArtifact.cleanup(artifact)
    refute branch?(repo, artifact.branch)
  end

  test "no-change output returns a clean reachable branch", %{job: job, repo: repo} do
    {:ok, artifact} = GitArtifact.provision_worktree(job)

    assert {:ok, result} = GitArtifact.finalize(artifact, job)
    assert result.head_sha == artifact.base_sha
    assert result.worktree_clean
    assert branch?(repo, artifact.branch)
    assert {:ok, ""} = git(artifact.path, ["status", "--porcelain"])

    assert :ok = GitArtifact.cleanup(artifact)
  end

  test "automatically commits safe dirty output with job metadata", %{job: job, repo: repo} do
    {:ok, artifact} = GitArtifact.provision_worktree(job)
    File.write!(Path.join(artifact.path, "README.md"), "generated\n")

    assert {:ok, result} = GitArtifact.finalize(artifact, job)
    assert result.head_sha != artifact.base_sha

    assert git!(repo, ["show", "-s", "--format=%s", artifact.branch]) ==
             "chore(omashiki): finalize job #{String.slice(job.id, 0, 8)}"

    assert git!(repo, ["show", "-s", "--format=%B", artifact.branch]) =~ "job_id: #{job.id}"
    assert :ok = GitArtifact.cleanup(artifact)
  end

  test "preserves an agent-created commit", %{job: job, repo: repo} do
    {:ok, artifact} = GitArtifact.provision_worktree(job)
    File.write!(Path.join(artifact.path, "agent.txt"), "agent\n")
    git!(artifact.path, ["add", "agent.txt"])
    git!(artifact.path, ["commit", "-q", "-m", "agent commit"], identity_env())
    agent_head = git!(artifact.path, ["rev-parse", "HEAD"])

    assert {:ok, %{head_sha: ^agent_head}} = GitArtifact.finalize(artifact, job)
    assert git!(repo, ["rev-parse", artifact.branch]) == agent_head
    assert :ok = GitArtifact.cleanup(artifact)
  end

  test "rejects protected paths and likely secrets without committing", %{job: job} do
    {:ok, protected} = GitArtifact.provision_worktree(job)
    File.write!(Path.join(protected.path, ".env"), "SAFE=not-a-secret\n")
    assert {:error, {:protected_path, ".env"}} = GitArtifact.finalize(protected, job)
    assert :ok = GitArtifact.cleanup(protected)

    secret_job = %{job | id: job.id <> "-secret"}
    {:ok, secret} = GitArtifact.provision_worktree(secret_job)
    File.write!(Path.join(secret.path, "notes.txt"), "api_key=sk-live-1234567890\n")
    assert {:error, {:likely_secret, "notes.txt"}} = GitArtifact.finalize(secret, secret_job)
    assert :ok = GitArtifact.cleanup(secret)
  end

  test "rejects output over the automatic commit bound", %{job: job} do
    {:ok, artifact} = GitArtifact.provision_worktree(job)
    File.write!(Path.join(artifact.path, "large.bin"), String.duplicate("x", 32))

    assert {:error, {:oversized_output, 32, 16}} =
             GitArtifact.finalize(artifact, job, max_bytes: 16)

    assert :ok = GitArtifact.cleanup(artifact)
  end

  test "does not commit when a pre-commit hook fails", %{job: job} do
    {:ok, artifact} = GitArtifact.provision_worktree(job)
    File.write!(Path.join(artifact.path, "README.md"), "generated\n")
    install_hook!(artifact.repo_path, "#!/bin/sh\nexit 42\n")

    assert {:error, {:commit_failed, _status, _output}} = GitArtifact.finalize(artifact, job)
    assert git!(artifact.path, ["rev-parse", "HEAD"]) == artifact.base_sha
    assert :ok = GitArtifact.cleanup(artifact)
  end

  test "rejects output that remains dirty after the hook", %{job: job} do
    {:ok, artifact} = GitArtifact.provision_worktree(job)
    File.write!(Path.join(artifact.path, "README.md"), "generated\n")
    install_hook!(artifact.repo_path, "#!/bin/sh\nprintf dirty > hook-dirty.txt\nexit 0\n")

    assert {:error, :artifact_verification_failed} = GitArtifact.finalize(artifact, job)
    assert git!(artifact.path, ["rev-parse", "HEAD"]) == artifact.base_sha
    assert :ok = GitArtifact.cleanup(artifact)
  end

  test "accepts output exactly at the 100 MiB automatic commit boundary", %{job: job} do
    {:ok, artifact} = GitArtifact.provision_worktree(job)
    path = Path.join(artifact.path, "boundary.bin")
    {:ok, file} = File.open(path, [:write, :binary])
    {:ok, _position} = :file.position(file, {:bof, GitArtifact.max_bytes() - 1})
    :ok = IO.binwrite(file, "x")
    :ok = File.close(file)

    assert {:ok, result} = GitArtifact.finalize(artifact, job)
    assert result.head_sha != artifact.base_sha
    assert :ok = GitArtifact.cleanup(artifact)
  end

  test "rejects symlink output before it can be committed", %{job: job} do
    {:ok, artifact} = GitArtifact.provision_worktree(job)
    outside = Path.join(System.tmp_dir!(), "omashiki-artifact-outside-#{System.unique_integer()}")
    File.write!(outside, "outside")
    File.ln_s!(outside, Path.join(artifact.path, "link"))

    assert {:error, {:symlink_path, "link"}} = GitArtifact.finalize(artifact, job)
    assert :ok = GitArtifact.cleanup(artifact)
    File.rm!(outside)
  end

  test "collision, cancellation, and callback failures clean up safely", %{job: job} do
    {:ok, artifact} = GitArtifact.provision_worktree(job)
    assert {:error, {:collision, _, _}} = GitArtifact.provision_worktree(job)
    assert {:error, :cancelled} = GitArtifact.finalize(artifact, job, cancelled?: fn -> true end)
    assert :ok = GitArtifact.cleanup(artifact)

    cancelled_job = %{job | id: job.id <> "-cancelled"}

    assert {:error, :cancelled} =
             GitArtifact.provision_worktree(cancelled_job, cancelled?: fn -> true end)

    failed_job = %{job | id: job.id <> "-callback"}

    assert {:error, :container_failed} =
             GitArtifact.provision(failed_job, [], fn _artifact -> {:error, :container_failed} end)

    refute branch?(failed_job.repository_snapshot["path"], "omashiki/job-#{failed_job.id}")
  end

  test "prunes expired successful branches but retains recent branches", %{job: job, repo: repo} do
    {:ok, old} = GitArtifact.provision_worktree(job)
    old_date = "2000-01-01T00:00:00Z"
    git!(old.path, ["commit", "--allow-empty", "-q", "-m", "old"], identity_env(old_date))
    assert {:ok, _} = GitArtifact.finalize(old, job)

    recent_job = %{job | id: job.id <> "-recent"}
    {:ok, recent} = GitArtifact.provision_worktree(recent_job)
    assert {:ok, _} = GitArtifact.finalize(recent, recent_job)
    assert :ok = GitArtifact.cleanup(old, preserve_branch: true)
    assert :ok = GitArtifact.cleanup(recent, preserve_branch: true)

    assert {:ok, pruned} =
             GitArtifact.prune_expired(repo, cutoff: System.system_time(:second) - 1)

    assert old.branch in pruned
    refute recent.branch in pruned
    assert branch?(repo, recent.branch)
    assert :ok = GitArtifact.cleanup(recent)
  end

  defp install_hook!(repo, contents) do
    hook = Path.join([repo, ".git", "hooks", "pre-commit"])
    File.write!(hook, contents)
    File.chmod!(hook, 0o755)
  end

  defp branch?(repo, branch),
    do: git(repo, ["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"]) == {:ok, ""}

  defp git!(path, args, env \\ []) do
    case git(path, args, env) do
      {:ok, output} -> output
      {:error, reason} -> flunk("git failed: #{inspect(reason)}")
    end
  end

  defp git(path, args, env \\ []) do
    case System.cmd("git", ["-C", path | args], env: env, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {status, String.trim(output)}}
    end
  end

  defp identity_env(date \\ nil) do
    base = [
      {"GIT_AUTHOR_NAME", "Tester"},
      {"GIT_AUTHOR_EMAIL", "tester@example.com"},
      {"GIT_COMMITTER_NAME", "Tester"},
      {"GIT_COMMITTER_EMAIL", "tester@example.com"}
    ]

    if date, do: [{"GIT_AUTHOR_DATE", date}, {"GIT_COMMITTER_DATE", date} | base], else: base
  end
end
