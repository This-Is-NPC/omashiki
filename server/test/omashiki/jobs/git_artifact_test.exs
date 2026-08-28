defmodule Omashiki.Jobs.GitArtifactTest do
  use ExUnit.Case, async: false

  alias Omashiki.Config
  alias Omashiki.Jobs.{GitArtifact, Job, JobAttempt}
  import Omashiki.Fixtures

  setup do
    root =
      Path.join(System.tmp_dir!(), "omashiki-git-artifact-#{System.unique_integer([:positive])}")

    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    copy_plugins!(root)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["commit", "--allow-empty", "-q", "-m", "init"], identity_env())

    task_branch = "feat-fix"
    job_id = "job-#{System.unique_integer([:positive])}"

    job = %Job{
      id: job_id,
      current_attempt: 2,
      admitted_repository: %{
        "path" => repo,
        "base_branch" => "main",
        "task_branch" => task_branch
      }
    }

    attempt = %JobAttempt{number: 2}

    on_exit(fn -> Config.reset!() end)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, job: job, attempt: attempt, repo: repo, task_branch: task_branch}
  end

  test "captures base SHA and creates an isolated job worktree", %{
    job: job,
    repo: repo,
    attempt: attempt
  } do
    assert {:ok, artifact} = GitArtifact.provision_worktree(job, attempt)
    assert artifact.run_branch == "feat-fix-run-002"
    assert artifact.base_sha == git!(repo, ["rev-parse", "main"])
    assert File.dir?(artifact.path)

    assert :ok = GitArtifact.cleanup(artifact)
    refute branch?(repo, artifact.branch)
  end

  test "no-change output returns a clean reachable branch", %{
    job: job,
    repo: repo,
    attempt: attempt
  } do
    {:ok, artifact} = GitArtifact.provision_worktree(job, attempt)

    assert {:ok, result} = GitArtifact.finalize(artifact, job, update_task_branch: true)
    assert result.head_sha == artifact.base_sha
    assert result.worktree_clean
    assert branch?(repo, artifact.branch)
    assert {:ok, ""} = git(artifact.path, ["status", "--porcelain"])

    assert :ok = GitArtifact.cleanup(artifact)
  end

  test "automatically commits safe dirty output with job metadata", %{
    job: job,
    repo: repo,
    attempt: attempt
  } do
    {:ok, artifact} = GitArtifact.provision_worktree(job, attempt)
    File.write!(Path.join(artifact.path, "README.md"), "generated\n")

    assert {:ok, result} = GitArtifact.finalize(artifact, job, update_task_branch: true)
    assert result.head_sha != artifact.base_sha

    assert git!(repo, ["show", "-s", "--format=%s", artifact.branch]) ==
             "chore(omashiki): finalize job #{String.slice(job.id, 0, 8)}"

    assert git!(repo, ["show", "-s", "--format=%B", artifact.branch]) =~ "job_id: #{job.id}"
    assert :ok = GitArtifact.cleanup(artifact)
  end

  test "preserves an agent-created commit", %{job: job, repo: repo, attempt: attempt} do
    {:ok, artifact} = GitArtifact.provision_worktree(job, attempt)
    File.write!(Path.join(artifact.path, "agent.txt"), "agent\n")
    git!(artifact.path, ["add", "agent.txt"])
    git!(artifact.path, ["commit", "-q", "-m", "agent commit"], identity_env())
    agent_head = git!(artifact.path, ["rev-parse", "HEAD"])

    assert {:ok, %{head_sha: ^agent_head}} =
             GitArtifact.finalize(artifact, job, update_task_branch: true)

    assert git!(repo, ["rev-parse", artifact.branch]) == agent_head
    assert :ok = GitArtifact.cleanup(artifact)
  end

  test "rejects protected paths and likely secrets without committing", %{
    job: job,
    attempt: attempt
  } do
    {:ok, protected} = GitArtifact.provision_worktree(job, attempt)
    File.write!(Path.join(protected.path, ".env"), "SAFE=not-a-secret\n")

    assert {:error, {:protected_path, ".env"}} =
             GitArtifact.finalize(protected, job, update_task_branch: true)

    assert :ok = GitArtifact.cleanup(protected)

    secret_job = %{
      job
      | id: job.id <> "-secret",
        admitted_repository: Map.put(job.admitted_repository, "task_branch", "feat-secret")
    }

    {:ok, secret} = GitArtifact.provision_worktree(secret_job, attempt)
    File.write!(Path.join(secret.path, "notes.txt"), "api_key=sk-live-1234567890\n")

    assert {:error, {:likely_secret, "notes.txt"}} =
             GitArtifact.finalize(secret, secret_job, update_task_branch: true)

    assert :ok = GitArtifact.cleanup(secret)
  end

  test "rejects output over the automatic commit bound", %{job: job, attempt: attempt} do
    {:ok, artifact} = GitArtifact.provision_worktree(job, attempt)
    File.write!(Path.join(artifact.path, "large.bin"), String.duplicate("x", 32))

    assert {:error, {:oversized_output, 32, 16}} =
             GitArtifact.finalize(artifact, job, max_bytes: 16)

    assert :ok = GitArtifact.cleanup(artifact)
  end

  test "does not commit when a pre-commit hook fails", %{job: job, attempt: attempt} do
    {:ok, artifact} = GitArtifact.provision_worktree(job, attempt)
    File.write!(Path.join(artifact.path, "README.md"), "generated\n")
    install_hook!(artifact.repo_path, "#!/bin/sh\nexit 42\n")

    assert {:error, {:commit_failed, _status, _output}} =
             GitArtifact.finalize(artifact, job, update_task_branch: true)

    assert git!(artifact.path, ["rev-parse", "HEAD"]) == artifact.base_sha
    assert :ok = GitArtifact.cleanup(artifact)
  end

  test "rejects output that remains dirty after the hook", %{job: job, attempt: attempt} do
    {:ok, artifact} = GitArtifact.provision_worktree(job, attempt)
    File.write!(Path.join(artifact.path, "README.md"), "generated\n")
    install_hook!(artifact.repo_path, "#!/bin/sh\nprintf dirty > hook-dirty.txt\nexit 0\n")

    assert {:error, :artifact_verification_failed} =
             GitArtifact.finalize(artifact, job, update_task_branch: true)

    assert git!(artifact.path, ["rev-parse", "HEAD"]) == artifact.base_sha
    assert :ok = GitArtifact.cleanup(artifact)
  end

  test "accepts output exactly at the 100 MiB automatic commit boundary", %{
    job: job,
    attempt: attempt
  } do
    {:ok, artifact} = GitArtifact.provision_worktree(job, attempt)
    path = Path.join(artifact.path, "boundary.bin")
    {:ok, file} = File.open(path, [:write, :binary])
    {:ok, _position} = :file.position(file, {:bof, GitArtifact.max_bytes() - 1})
    :ok = IO.binwrite(file, "x")
    :ok = File.close(file)

    assert {:ok, result} = GitArtifact.finalize(artifact, job, update_task_branch: true)
    assert result.head_sha != artifact.base_sha
    assert :ok = GitArtifact.cleanup(artifact)
  end

  test "rejects symlink output before it can be committed", %{job: job, attempt: attempt} do
    {:ok, artifact} = GitArtifact.provision_worktree(job, attempt)
    outside = Path.join(System.tmp_dir!(), "omashiki-artifact-outside-#{System.unique_integer()}")
    File.write!(outside, "outside")
    File.ln_s!(outside, Path.join(artifact.path, "link"))

    assert {:error, {:symlink_path, "link"}} =
             GitArtifact.finalize(artifact, job, update_task_branch: true)

    assert :ok = GitArtifact.cleanup(artifact)
    File.rm!(outside)
  end

  test "collision, cancellation, and callback failures clean up safely", %{
    job: job,
    attempt: attempt
  } do
    {:ok, artifact} = GitArtifact.provision_worktree(job, attempt)
    assert {:error, {:collision, _, _}} = GitArtifact.provision_worktree(job, attempt)
    assert {:error, :cancelled} = GitArtifact.finalize(artifact, job, cancelled?: fn -> true end)
    assert :ok = GitArtifact.cleanup(artifact)

    cancelled_job = %{job | id: job.id <> "-cancelled"}

    assert {:error, :cancelled} =
             GitArtifact.provision_worktree(cancelled_job, attempt, cancelled?: fn -> true end)

    failed_job = %{job | id: job.id <> "-callback"}

    assert {:error, :container_failed} =
             GitArtifact.provision(failed_job, attempt, [], fn _artifact ->
               {:error, :container_failed}
             end)

    refute branch?(failed_job.admitted_repository["path"], "feat-fix-run-002")
  end

  test "prunes expired successful branches but retains recent branches", %{
    job: job,
    repo: repo,
    attempt: attempt
  } do
    {:ok, old} = GitArtifact.provision_worktree(job, attempt)
    old_date = "2000-01-01T00:00:00Z"
    git!(old.path, ["commit", "--allow-empty", "-q", "-m", "old"], identity_env(old_date))
    assert {:ok, _} = GitArtifact.finalize(old, job, update_task_branch: true)

    recent_job = %{
      job
      | id: job.id <> "-recent",
        admitted_repository: Map.put(job.admitted_repository, "task_branch", "feat-recent")
    }

    {:ok, recent} = GitArtifact.provision_worktree(recent_job, attempt)
    assert {:ok, _} = GitArtifact.finalize(recent, recent_job, update_task_branch: true)
    assert :ok = GitArtifact.cleanup(old, preserve_branch: true)
    assert :ok = GitArtifact.cleanup(recent, preserve_branch: true)

    assert {:ok, pruned} =
             GitArtifact.prune_expired(repo, cutoff: System.system_time(:second) - 1)

    assert old.run_branch in pruned
    refute recent.run_branch in pruned
    assert branch?(repo, recent.run_branch)
    assert :ok = GitArtifact.cleanup(recent)
  end

  # The canonical remote is a bare repository on this filesystem and the second
  # node is a second clone of it. That is a proxy for two machines — one host,
  # but the identical Git transport and ref-negotiation path — and the proxy is
  # the only simulated part of the claim.
  describe "canonical remote" do
    test "publishes the branch so a clone that never ran the attempt can fetch it", ctx do
      canonical = canonical_remote!(ctx)
      job = at_node(ctx.job, ctx.repo, canonical)

      {:ok, artifact} = GitArtifact.provision_worktree(job, ctx.attempt)
      File.write!(Path.join(artifact.path, "delivered.txt"), "artifact\n")

      assert {:ok, result} = GitArtifact.finalize(artifact, job, update_task_branch: true)
      assert result.remote == canonical
      assert result.result["remote"] == canonical

      observer = clone!(ctx, canonical, "observer")

      assert git!(observer, ["rev-parse", "refs/remotes/origin/#{result.branch}"]) ==
               result.head_sha

      assert git!(observer, ["show", "origin/#{result.branch}:delivered.txt"]) == "artifact"
      assert :ok = GitArtifact.cleanup(artifact)
    end

    test "detects a colliding branch on the remote instead of dropping an artifact", ctx do
      canonical = canonical_remote!(ctx)
      second_node = clone!(ctx, canonical, "node-b")

      first_job = at_node(ctx.job, ctx.repo, canonical)
      second_job = at_node(ctx.job, second_node, canonical)

      attempt = ctx.attempt

      {:ok, first} = GitArtifact.provision_worktree(first_job, attempt)
      {:ok, second} = GitArtifact.provision_worktree(second_job, attempt)
      assert first.run_branch == second.run_branch

      File.write!(Path.join(first.path, "out.txt"), "first node\n")
      File.write!(Path.join(second.path, "out.txt"), "second node\n")

      assert {:ok, published} = GitArtifact.finalize(first, first_job, update_task_branch: true)

      assert {:error, {:collision, :remote, branch}} =
               GitArtifact.finalize(second, second_job, update_task_branch: true)

      assert branch == first.run_branch
      assert git!(canonical, ["rev-parse", "refs/heads/#{branch}"]) == published.head_sha

      assert :ok = GitArtifact.cleanup(first)
      assert :ok = GitArtifact.cleanup(second)
    end

    test "prunes an expired remote branch from a node that never held it locally", ctx do
      canonical = canonical_remote!(ctx)
      attempt = ctx.attempt
      old_job = at_node(ctx.job, ctx.repo, canonical)

      recent_job =
        at_node(%{ctx.job | id: ctx.job.id <> "-recent"}, ctx.repo, canonical)
        |> then(fn job ->
          %{
            job
            | admitted_repository:
                Map.put(job.admitted_repository, "task_branch", "feat-recent-remote")
          }
        end)

      {:ok, old} = GitArtifact.provision_worktree(old_job, attempt)

      git!(
        old.path,
        ["commit", "--allow-empty", "-q", "-m", "old"],
        identity_env("2000-01-01T00:00:00Z")
      )

      assert {:ok, _} = GitArtifact.finalize(old, old_job, update_task_branch: true)
      assert :ok = GitArtifact.cleanup(old)

      {:ok, recent} = GitArtifact.provision_worktree(recent_job, attempt)
      assert {:ok, _} = GitArtifact.finalize(recent, recent_job, update_task_branch: true)
      assert :ok = GitArtifact.cleanup(recent)

      sweeper = clone!(ctx, canonical, "sweeper")
      refute branch?(sweeper, old.run_branch)

      assert {:ok, pruned} =
               GitArtifact.prune_expired(sweeper,
                 remote: canonical,
                 cutoff: System.system_time(:second) - 1
               )

      assert old.run_branch in pruned
      refute recent.run_branch in pruned
      refute branch?(canonical, old.run_branch)
      assert branch?(canonical, recent.run_branch)
    end
  end

  describe "managed mirror" do
    test "clones a missing path from the remote then creates the worktree", ctx do
      canonical = canonical_remote!(ctx)
      mirror = Path.join(ctx.root, "managed-mirror")
      refute File.exists?(mirror)

      job = at_node(ctx.job, mirror, canonical)

      assert {:ok, artifact} = GitArtifact.provision_worktree(job, ctx.attempt)
      assert File.dir?(Path.join(mirror, ".git"))
      assert File.dir?(artifact.path)
      assert artifact.base_sha == git!(canonical, ["rev-parse", "refs/heads/main"])
      assert :ok = GitArtifact.cleanup(artifact)
    end
  end

  describe "host Git credentials" do
    test "SSH passphrase environment is absent from local commit hooks", ctx do
      canonical = canonical_remote!(ctx)
      passphrase_var = "OMASHIKI_TEST_GIT_KEY_PASSPHRASE"
      previous = System.get_env(passphrase_var)
      System.put_env(passphrase_var, "hook-secret")

      on_exit(fn ->
        if previous,
          do: System.put_env(passphrase_var, previous),
          else: System.delete_env(passphrase_var)
      end)

      Config.load_map!(
        %{
          "repositories" => %{
            "app" => %{
              "path" => "repo",
              "base_branch" => "main",
              "remote" => canonical,
              "ssh_key" => "/home/operator/.ssh/omashiki_deploy",
              "ssh_key_passphrase" => "${env:OMASHIKI_TEST_GIT_KEY_PASSPHRASE}"
            }
          },
          "presets" => %{"opencode" => %{"plugin" => "opencode", "options" => %{}}},
          "environments" => %{
            "git" => %{
              "preset" => "opencode",
              "isolation" => "docker",
              "image" => "omashiki/agent:latest",
              "sink" => "git",
              "packages" => [],
              "executables" => ["git"],
              "credentials" => [],
              "timeout_ms" => 1_000,
              "caches" => [],
              "mounts" => [],
              "pre_steps" => [],
              "post_steps" => [],
              "policy" => %{"mode" => "off"},
              "network" => "none",
              "resources" => %{"cpus" => 1, "memory" => "1GB", "pids" => 32}
            }
          }
        },
        path: Path.join(ctx.root, "omashiki.toml")
      )

      job = %{at_node(ctx.job, ctx.repo, canonical) | repository: "app"}
      {:ok, artifact} = GitArtifact.provision_worktree(job, ctx.attempt)
      File.write!(Path.join(artifact.path, "generated.txt"), "generated\n")

      install_hook!(
        artifact.repo_path,
        "#!/bin/sh\nif test -n \"${OMASHIKI_GIT_ASKPASS_PASSPHRASE-}\"; then exit 42; fi\nif test -n \"${GIT_SSH_COMMAND-}\"; then exit 43; fi\nexit 0\n"
      )

      install_hook!(
        artifact.repo_path,
        "#!/bin/sh\nif test -n \"${OMASHIKI_GIT_ASKPASS_PASSPHRASE-}\"; then exit 42; fi\nif test -n \"${GIT_SSH_COMMAND-}\"; then exit 43; fi\nexit 0\n",
        "pre-push"
      )

      assert {:ok, result} = GitArtifact.finalize(artifact, job, update_task_branch: true)
      assert result.worktree_clean
      assert :ok = GitArtifact.cleanup(artifact)
    end
  end

  describe "task branch and run-NNN" do
    test "two attempts create two run branches; task branch follows the succeeded head", %{
      repo: repo,
      task_branch: task_branch
    } do
      job = %Job{
        id: "job-#{System.unique_integer([:positive])}",
        current_attempt: 1,
        admitted_repository: %{
          "path" => repo,
          "base_branch" => "main",
          "task_branch" => task_branch
        }
      }

      attempt1 = %JobAttempt{number: 1}
      attempt2 = %JobAttempt{number: 2}

      {:ok, first} = GitArtifact.provision_worktree(job, attempt1)
      File.write!(Path.join(first.path, "run1.txt"), "one\n")
      assert {:ok, _} = GitArtifact.finalize(first, job, update_task_branch: true)
      first_head = git!(repo, ["rev-parse", task_branch])
      assert :ok = GitArtifact.cleanup(first, preserve_branch: true)

      job2 = %{job | current_attempt: 2}
      {:ok, second} = GitArtifact.provision_worktree(job2, attempt2)
      File.write!(Path.join(second.path, "run2.txt"), "two\n")
      assert {:ok, _} = GitArtifact.finalize(second, job2, update_task_branch: true)
      second_head = git!(repo, ["rev-parse", task_branch])
      assert second_head != first_head
      assert branch?(repo, "#{task_branch}-run-001")
      assert branch?(repo, "#{task_branch}-run-002")
      assert :ok = GitArtifact.cleanup(first, preserve_branch: true)
      assert :ok = GitArtifact.cleanup(second, preserve_branch: true)
    end

    test "failed dirty attempt keeps the run branch but does not advance the task branch", %{
      repo: repo,
      task_branch: task_branch,
      job: job,
      attempt: attempt
    } do
      {:ok, artifact} = GitArtifact.provision_worktree(job, attempt)
      File.write!(Path.join(artifact.path, "dirty.txt"), "dirty\n")
      assert {:ok, _} = GitArtifact.finalize(artifact, job)
      assert branch?(repo, artifact.run_branch)
      refute branch?(repo, task_branch)
      assert :ok = GitArtifact.cleanup(artifact, preserve_branch: true)
    end

    test "re-provisioning the same run branch collides", %{job: job, attempt: attempt} do
      {:ok, artifact} = GitArtifact.provision_worktree(job, attempt)
      assert {:error, {:collision, _, _}} = GitArtifact.provision_worktree(job, attempt)
      assert :ok = GitArtifact.cleanup(artifact)
    end

    test "concurrent same-worktree provisioning leaves the winner intact", %{
      job: job,
      attempt: attempt
    } do
      tasks =
        for _ <- 1..2 do
          Task.async(fn -> GitArtifact.provision_worktree(job, attempt) end)
        end

      results = Enum.map(tasks, &Task.await(&1, 30_000))
      artifacts = for {:ok, artifact} <- results, do: artifact

      assert [artifact] = artifacts
      assert Enum.any?(results, &match?({:error, {:collision, _, _}}, &1))
      assert File.dir?(artifact.path)
      assert branch?(artifact.repo_path, artifact.run_branch)
      assert :ok = GitArtifact.cleanup(artifact)
    end
  end

  defp canonical_remote!(%{root: root, repo: repo}) do
    canonical = Path.join(root, "canonical.git")
    git!(root, ["init", "--bare", "-q", "-b", "main", canonical])
    git!(repo, ["push", "-q", canonical, "refs/heads/main:refs/heads/main"])
    canonical
  end

  defp clone!(%{root: root}, source, name) do
    target = Path.join(root, name)
    git!(root, ["clone", "--quiet", source, target])
    target
  end

  defp at_node(%Job{} = job, path, remote) do
    %{
      job
      | admitted_repository: %{
          "path" => path,
          "base_branch" => "main",
          "remote" => remote,
          "task_branch" => "feat-deliver"
        }
    }
  end

  defp install_hook!(repo, contents, name \\ "pre-commit") do
    hook = Path.join([repo, ".git", "hooks", name])
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
