defmodule Omashiki.JobFixtures do
  alias Omashiki.Jobs.{Failure, Job, JobAttempt, SecretScan, Statuses}
  alias Omashiki.Repo

  def job_fixture(user, token, attrs \\ %{}) do
    now = DateTime.utc_now(:microsecond)
    status = Map.get(attrs, :status, "queued")
    id = System.unique_integer([:positive])

    values =
      Map.merge(
        %{
          user_id: user.id,
          api_token_id: token.id,
          idempotency_key: "fixture-#{id}",
          correlation_id: "corr-#{id}",
          repository: "omashiki",
          environment: "opencode",
          payload: %{"instruction" => "test", "branch" => "feat-fixture"},
          payload_hash: String.duplicate("a", 64),
          admitted_repository: %{"name" => "omashiki", "task_branch" => "feat-fixture"},
          admitted_repository_digest: String.duplicate("b", 64),
          admitted_environment: %{"name" => "opencode", "sink" => "git"},
          admitted_environment_digest: String.duplicate("c", 64),
          admitted_plugin: %{
            "path" => "plugins/opencode.toml",
            "contents" => "",
            "digest" => String.duplicate("e", 64)
          },
          admitted_plugin_digest: String.duplicate("e", 64),
          registry_digest: String.duplicate("d", 64),
          queue: "default",
          priority: 1,
          status: status,
          current_attempt: 1,
          queued_at: if(status == "blocked", do: nil, else: now),
          started_at: if(status in ~w(provisioning running review succeeded failed), do: now),
          finished_at: if(Statuses.terminal?(status), do: now),
          terminal_result: if(status == "succeeded", do: %{"ok" => true}),
          terminal_error: fixture_error(status),
          review: fixture_review(status)
        },
        attrs
      )

    job = %Job{} |> Job.changeset(values) |> Repo.insert!()

    attempt_values = %{
      job_id: job.id,
      number: 1,
      status: status,
      finished_at: if(Statuses.terminal?(status), do: now),
      result: if(status == "succeeded", do: %{"ok" => true}),
      error: fixture_error(status),
      started_at: if(status in ~w(provisioning running review succeeded failed), do: now),
      lease_token: if(Statuses.active?(status) or status == "review", do: "fixture-lease"),
      lease_expires_at: if(Statuses.active?(status), do: DateTime.add(now, 60, :second)),
      capacity_reserved: Statuses.active?(status),
      branch: if(status == "succeeded", do: "feat-fixture-run-001"),
      base_sha: if(status == "succeeded", do: String.duplicate("1", 40)),
      head_sha: if(status == "succeeded", do: String.duplicate("2", 40)),
      worktree_clean: if(status == "succeeded", do: true)
    }

    attempt = %JobAttempt{} |> JobAttempt.changeset(attempt_values) |> Repo.insert!()
    {job, attempt}
  end

  defp fixture_error("failed"), do: Failure.error(:failed)
  defp fixture_error("cancelled"), do: Failure.error(:cancelled)
  defp fixture_error(_status), do: nil

  # A held job: gitleaks found one GitHub token in docs/notes.txt.
  defp fixture_review("review") do
    finding = %SecretScan.Finding{
      file: "docs/notes.txt",
      line: 3,
      rule_id: "github-pat",
      description: "GitHub Personal Access Token",
      match: "export GH=REDACTED",
      fingerprint: String.duplicate("f", 64)
    }

    %{
      "error" =>
        Failure.error({:finalization_failed, {:secret_found, [finding]}}, "finalization"),
      "node" => "worker-a",
      "decision" => nil
    }
  end

  defp fixture_review(_status), do: nil
end
