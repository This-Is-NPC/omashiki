defmodule Omashiki.JobFixtures do
  alias Omashiki.Jobs.{Job, JobAttempt}
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
          schema_version: 1,
          idempotency_key: "fixture-#{id}",
          correlation_id: "corr-#{id}",
          repository: "omashiki",
          environment: "opencode",
          payload: %{"instruction" => "test"},
          payload_hash: String.duplicate("a", 64),
          admitted_repository: %{"name" => "omashiki"},
          admitted_repository_digest: String.duplicate("b", 64),
          admitted_environment: %{"name" => "opencode", "sink" => "git"},
          admitted_environment_digest: String.duplicate("c", 64),
          admitted_plugin: %{"path" => "plugins/opencode.toml", "contents" => "", "digest" => String.duplicate("e", 64)},
          admitted_plugin_digest: String.duplicate("e", 64),
          registry_digest: String.duplicate("d", 64),
          queue: "default",
          priority: 1,
          status: status,
          current_attempt: 1,
          queued_at: if(status == "blocked", do: nil, else: now),
          started_at: if(status in ~w(provisioning running succeeded failed), do: now),
          finished_at: if(status in ~w(failed cancelled succeeded), do: now),
          terminal_result: if(status == "succeeded", do: %{"ok" => true}),
          terminal_error: if(status in ~w(failed cancelled), do: %{"code" => status})
        },
        attrs
      )

    job = %Job{} |> Job.changeset(values) |> Repo.insert!()

    attempt_values = %{
      job_id: job.id,
      number: 1,
      status: status,
      finished_at: if(status in ~w(failed cancelled succeeded), do: now),
      result: if(status == "succeeded", do: %{"ok" => true}),
      error: if(status in ~w(failed cancelled), do: %{"code" => status}),
      started_at: if(status in ~w(provisioning running succeeded failed), do: now),
      lease_token: if(status in ~w(provisioning running), do: "fixture-lease"),
      lease_expires_at:
        if(status in ~w(provisioning running), do: DateTime.add(now, 60, :second)),
      capacity_reserved: status in ~w(provisioning running),
      branch: if(status == "succeeded", do: "omashiki/job-#{String.slice(job.id, 0, 8)}"),
      base_sha: if(status == "succeeded", do: String.duplicate("1", 40)),
      head_sha: if(status == "succeeded", do: String.duplicate("2", 40)),
      worktree_clean: if(status == "succeeded", do: true)
    }

    attempt = %JobAttempt{} |> JobAttempt.changeset(attempt_values) |> Repo.insert!()
    {job, attempt}
  end
end
