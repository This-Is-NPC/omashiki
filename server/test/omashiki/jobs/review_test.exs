defmodule Omashiki.Jobs.ReviewTest do
  use Omashiki.DataCase, async: false

  alias Omashiki.Config
  alias Omashiki.Jobs

  alias Omashiki.Jobs.{
    Admission,
    GitArtifact,
    HeldOutput,
    Job,
    JobAttempt,
    JobEvent,
    Runner,
    SecretAllowances,
    WebhookDelivery,
    Webhooks
  }

  alias Omashiki.Jobs.HeldOutput.Sweeper
  alias Omashiki.LeakyContainer

  import Ecto.Query

  defmodule FakeHarness do
    def invoke(_invocation, _context),
      do: {:ok, %Omashiki.Harness.Result{assistant_text: "wrote the notes"}}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "omashiki-review-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["commit", "--allow-empty", "-q", "-m", "init"])

    previous_root = Application.get_env(:omashiki, :held_output_root)
    Application.put_env(:omashiki, :held_output_root, Path.join(root, "held"))

    Config.load_map!(
      %{
        "repositories" => %{"app" => %{"path" => "repo", "base_branch" => "main"}},
        "presets" => %{"opencode" => %{"plugin" => "opencode", "options" => %{}}},
        "runtimes" => %{
          "docker" => %{
            "runc" => %{"debian" => %{"images" => %{"opencode" => "omashiki/agent:latest"}}}
          }
        },
        "environments" => %{
          "notes" => environment("files", %{}),
          "code" => environment("git", %{}),
          "strict" => environment("files", %{"secret_scan" => "block"}),
          "brief" => environment("files", %{"review_timeout_ms" => 90 * 60_000})
        },
        "webhooks" => %{"allow_private_destinations" => true},
        "limits" => %{}
      },
      path: Path.join(root, "omashiki.toml")
    )

    user = user_fixture()
    {token, _plaintext} = api_token_fixture(user)

    on_exit(fn ->
      Application.put_env(:omashiki, :held_output_root, previous_root)
      File.rm_rf!(root)
    end)

    {:ok, token: token, repo: repo}
  end

  describe "a secret in the output" do
    test "holds the job for review and keeps the output on the node", %{token: token} do
      {:ok, token} =
        Webhooks.configure(token, %{destination: "http://127.0.0.1:9/hook", secret: "hook-secret"})

      {job, attempt} = run(token, "notes")

      assert job.status == "review"
      assert is_nil(job.finished_at)
      assert %{"error" => error, "node" => node, "decision" => nil} = job.review
      assert node == Config.current_machine().name
      assert error["code"] == "secret_found"

      assert [%{"file" => "leak.txt", "rule_id" => "github-pat", "match" => match}] =
               error["details"]["findings"]

      assert match =~ "REDACTED"
      refute match =~ LeakyContainer.leak()

      held = Repo.get!(JobAttempt, attempt.id)
      assert held.status == "review"
      assert held.lease_token == attempt.lease_token
      assert is_nil(held.lease_expires_at)
      refute held.capacity_reserved
      assert Jobs.cluster_capacity().active == 0

      assert [%HeldOutput{attempt_id: attempt_id, manager_id: nil} = record] = HeldOutput.list()
      assert attempt_id == attempt.id
      assert File.read!(Path.join(record.artifact.path, "leak.txt")) =~ LeakyContainer.leak()

      event = Repo.one!(from(e in JobEvent, where: e.job_id == ^job.id and e.status == "review"))
      assert %JobEvent{type: "job.review", data: %{"error_code" => "secret_found"}} = event

      # Like any status a job passes through, review is an event; the webhook
      # comes when the job ends.
      refute Repo.get_by(WebhookDelivery, event_id: event.event_id)
      {:ok, _rejected} = Jobs.reject(job, "alice")

      assert [%WebhookDelivery{payload: %{"status" => "failed"}}] =
               Repo.all(WebhookDelivery)
    end

    test "fails the job and removes the output when the environment blocks", %{token: token} do
      {job, _attempt} = run(token, "strict")

      assert job.status == "failed"
      assert job.terminal_error["code"] == "secret_found"
      assert is_nil(job.review)
      assert HeldOutput.list() == []
    end

    test "leaves jobs that depend on it waiting", %{token: token} do
      {job, _attempt} = run(token, "notes")

      {:ok, _, child} =
        Admission.admit_once(
          token,
          request("notes", %{"depends_on" => [%{"id" => job.id}]})
        )

      assert child.status == "blocked"
      assert {:ok, 0} = Jobs.recover_stale(DateTime.add(DateTime.utc_now(), 3_600))
      assert Repo.get!(Job, child.id).status == "blocked"
    end

    test "holding again with the same fence changes nothing", %{token: token} do
      {job, attempt} = run(token, "notes")

      assert {:ok, %JobAttempt{status: "review"}} =
               Jobs.hold(attempt.id, attempt.lease_token, job.review["error"])

      assert Repo.aggregate(from(e in JobEvent, where: e.status == "review"), :count) == 1
    end
  end

  describe "the node holding the output" do
    test "keeps it while the job waits for review", %{token: token} do
      {job, _attempt} = run(token, "notes")
      [record] = HeldOutput.list()

      assert Sweeper.settle(record) == :held
      assert Repo.get!(Job, job.id).status == "review"
      assert File.exists?(record.artifact.path)
    end

    test "publishes files output once approved", %{token: token} do
      {job, _attempt} = run(token, "notes")
      [record] = HeldOutput.list()

      assert {:ok, approved} = Jobs.approve(job, "alice")
      assert approved.status == "review"
      assert %{"decision" => "approve", "decided_by" => "alice"} = approved.review
      assert {:ok, _same} = Jobs.approve(job, "bob")
      assert Repo.get!(Job, job.id).review["decided_by"] == "alice"

      assert Sweeper.settle(record) == :published

      job = Repo.get!(Job, job.id)
      assert job.status == "succeeded"
      assert job.review["decision"] == "approve"

      assert {:ok, files} =
               :erl_tar.extract(~c"#{job.terminal_result["blob_path"]}", [:compressed, :memory])

      assert [{~c"leak.txt", content}] = files
      assert content =~ LeakyContainer.leak()

      refute File.exists?(record.artifact.path)
      assert HeldOutput.list() == []
    end

    test "publishes git output once approved, on the task branch", %{token: token, repo: repo} do
      {job, attempt} = run(token, "code")
      [record] = HeldOutput.list()
      assert File.exists?(Path.join(record.artifact.path, "leak.txt"))

      # Boot cleanup prunes worktrees whose directory is gone, not held ones.
      :ok = GitArtifact.prune_worktrees()

      {:ok, _approved} = Jobs.approve(job, "alice")
      assert Sweeper.settle(record) == :published

      job = Repo.get!(Job, job.id)
      assert job.status == "succeeded"
      published = Repo.get!(JobAttempt, attempt.id)
      assert published.status == "succeeded"
      assert published.branch == "feat-review"
      assert published.summary == "wrote the notes"
      assert git!(repo, ["show", "feat-review:leak.txt"]) =~ LeakyContainer.leak()
      assert git!(repo, ["rev-parse", "feat-review-run-001"]) == published.head_sha
      refute File.exists?(record.artifact.path)
    end

    test "resends a published complete instead of publishing twice", %{token: token} do
      {job, _attempt} = run(token, "notes")
      [record] = HeldOutput.list()
      {:ok, _approved} = Jobs.approve(job, "alice")

      assert {:ok, published} = HeldOutput.publish(record)
      assert [%HeldOutput{complete: %{kind: :files}} = reread] = HeldOutput.list()
      assert reread.complete == published.complete

      assert Sweeper.settle(reread) == :delivered
      assert Repo.get!(Job, job.id).status == "succeeded"
      refute File.exists?(published.artifact.path)
      assert HeldOutput.list() == []
    end

    test "removes it when the job is rejected", %{token: token} do
      {job, attempt} = run(token, "notes")
      [record] = HeldOutput.list()

      assert {:ok, rejected} = Jobs.reject(job, "alice")
      assert rejected.status == "failed"
      assert rejected.terminal_error == job.review["error"]
      assert rejected.review["decision"] == "reject"

      failed = Repo.get!(JobAttempt, attempt.id)
      assert failed.status == "failed"
      assert is_nil(failed.lease_token)
      assert failed.error["code"] == "secret_found"

      assert {:error, {:invalid_transition, "failed", "succeeded"}} = Jobs.approve(job, "bob")
      assert Sweeper.settle(record) == {:discarded, :cancelled}
      refute File.exists?(record.artifact.path)
      assert HeldOutput.list() == []
    end

    test "removes it when the job is cancelled", %{token: token} do
      {job, _attempt} = run(token, "notes")
      [record] = HeldOutput.list()

      assert {:ok, %Job{status: "cancelled"}} = Jobs.cancel(job)
      assert Sweeper.settle(record) == {:discarded, :cancelled}
      refute File.exists?(record.artifact.path)
    end

    test "removes git output and its run branch when rejected", %{token: token, repo: repo} do
      {job, _attempt} = run(token, "code")
      [record] = HeldOutput.list()

      {:ok, _rejected} = Jobs.reject(job, "alice")
      assert Sweeper.settle(record) == {:discarded, :cancelled}

      refute File.exists?(record.artifact.path)

      assert {_, status} =
               System.cmd("git", ["-C", repo, "rev-parse", "--verify", "feat-review-run-001"],
                 stderr_to_stdout: true
               )

      assert status != 0
    end

    test "survives recovery and a restart of its sweeper", %{token: token} do
      {job, _attempt} = run(token, "notes")

      assert {:ok, 0} = Jobs.recover_stale(DateTime.add(DateTime.utc_now(), 3_600))
      assert {:ok, 0} = Jobs.recover_orphaned_dispatches(DateTime.add(DateTime.utc_now(), 3_600))
      assert Repo.get!(Job, job.id).status == "review"

      {:ok, _approved} = Jobs.approve(job, "alice")
      start_supervised!({Sweeper, interval_ms: 50})

      Omashiki.Await.until(fn -> Repo.get!(Job, job.id).status == "succeeded" end)
      assert HeldOutput.list() == []
    end
  end

  describe "a review past its deadline" do
    test "fails the job with review_expired, as a rejection would", %{token: token} do
      {:ok, token} =
        Webhooks.configure(token, %{destination: "http://127.0.0.1:9/hook", secret: "hook-secret"})

      {job, attempt} = run(token, "notes")
      [record] = HeldOutput.list()
      {:ok, deadline, _offset} = DateTime.from_iso8601(job.review["expires_at"])
      assert_in_delta DateTime.diff(deadline, DateTime.utc_now(), :day), 7, 1
      assert abs(DateTime.diff(deadline, record.expires_at, :second)) < 60

      assert {:ok, 0} = Jobs.expire_reviews(DateTime.add(deadline, -1, :second))
      assert Repo.get!(Job, job.id).status == "review"

      assert {:ok, 1} = Jobs.expire_reviews(deadline)

      expired = Repo.get!(Job, job.id)
      assert expired.status == "failed"
      assert expired.terminal_error["code"] == "review_expired"

      assert expired.terminal_error["message"] ==
               "Output waited for review for 7 days and was discarded."

      failed = Repo.get!(JobAttempt, attempt.id)
      assert failed.status == "failed"
      assert failed.error["code"] == "review_expired"

      event = Repo.one!(from(e in JobEvent, where: e.job_id == ^job.id and e.status == "failed"))
      assert %JobEvent{type: "job.failed", data: %{"error_code" => "review_expired"}} = event

      assert [%WebhookDelivery{payload: %{"status" => "failed"}}] =
               Repo.all(from(d in WebhookDelivery, where: d.event_id == ^event.event_id))

      assert {:ok, 0} = Jobs.expire_reviews(DateTime.add(deadline, 1, :day))
      assert Sweeper.settle(record) == {:discarded, :cancelled}
      refute File.exists?(record.artifact.path)
    end

    test "expires approved output the node never published", %{token: token} do
      {job, _attempt} = run(token, "notes")
      {:ok, _approved} = Jobs.approve(job, "alice")

      assert {:ok, 1} = Jobs.expire_reviews(DateTime.add(DateTime.utc_now(), 8, :day))
      assert Repo.get!(Job, job.id).terminal_error["code"] == "review_expired"
    end

    test "comes from the environment's review_timeout_ms", %{token: token} do
      {job, _attempt} = run(token, "brief")
      {:ok, deadline, _offset} = DateTime.from_iso8601(job.review["expires_at"])
      assert_in_delta DateTime.diff(deadline, DateTime.utc_now(), :second), 90 * 60, 60

      assert {:ok, 1} = Jobs.expire_reviews(DateTime.add(DateTime.utc_now(), 2, :hour))

      assert Repo.get!(Job, job.id).terminal_error["message"] ==
               "Output waited for review for 90 minutes and was discarded."
    end
  end

  describe "an allowed finding" do
    setup %{token: token} do
      user = Repo.preload(token, :user).user
      {job, _attempt} = run(token, "notes")
      [finding] = job.review["error"]["details"]["findings"]
      {:ok, job: job, finding: finding, user: user}
    end

    test "is recorded for the job's environment", %{job: job, finding: finding, user: user} do
      assert {:ok, allowance} =
               SecretAllowances.allow(job, finding["fingerprint"], user, "  test fixture  ")

      assert allowance.environment == "notes"
      assert is_nil(allowance.repository)
      assert allowance.file == "leak.txt"
      assert allowance.rule_id == "github-pat"
      assert allowance.note == "test fixture"
      assert allowance.created_by_id == user.id

      assert {:ok, same} = SecretAllowances.allow(job, finding["fingerprint"], user, nil)
      assert same.id == allowance.id
      assert SecretAllowances.fingerprints("notes", nil) == [finding["fingerprint"]]
      assert SecretAllowances.fingerprints("code", "app") == []

      assert {:error, :unknown_finding} =
               SecretAllowances.allow(job, String.duplicate("0", 64), user, nil)
    end

    test "lets the next job with the same secret publish normally",
         %{token: token, job: job, finding: finding, user: user} do
      {:ok, _allowance} = SecretAllowances.allow(job, finding["fingerprint"], user, nil)

      {next, _attempt} = run(token, "notes")

      assert next.status == "succeeded"
      assert is_nil(next.review)
      assert HeldOutput.list() |> Enum.map(& &1.job_id) == [job.id]
    end

    test "is refused again once removed", %{token: token, job: job, finding: finding, user: user} do
      {:ok, allowance} = SecretAllowances.allow(job, finding["fingerprint"], user, nil)
      assert {:ok, _deleted} = SecretAllowances.delete(allowance.id)
      assert {:error, :not_found} = SecretAllowances.delete(allowance.id)

      {next, _attempt} = run(token, "notes")
      assert next.status == "review"
    end
  end

  test "only the attempt's own fence is told to keep the output", %{token: token} do
    {_job, attempt} = run(token, "notes")

    assert Jobs.held_command(attempt.id, attempt.lease_token) == :ok
    assert Jobs.held_command(attempt.id, "another-token") == :cancel
    assert Jobs.held_command(Ecto.UUID.generate(), attempt.lease_token) == :cancel
  end

  test "only approved held output completes its attempt", %{token: token} do
    {_job, attempt} = run(token, "notes")

    assert {:error, :attempt_not_active} =
             Jobs.complete(attempt.id, attempt.lease_token, :succeeded, %{result: %{}})
  end

  defp run(token, environment) do
    {:ok, _, job} = Admission.admit_once(token, request(environment))
    {:ok, attempt} = Jobs.claim(job, "review-test")

    {:ok, _job} =
      Runner.run(attempt,
        container: LeakyContainer,
        adapter: FakeHarness,
        secret_scan: SecretAllowances.policy(job)
      )

    {Repo.get!(Job, job.id), attempt}
  end

  defp request(environment, extra \\ %{}) do
    repo = if environment == "code", do: %{"repo" => "app"}, else: %{}

    %{
      "idempotency_key" => "review-#{System.unique_integer([:positive])}",
      "correlation_id" => "review",
      "environment" => environment,
      "payload" => %{"instruction" => "write notes", "branch" => "feat-review"},
      "priority" => 0
    }
    |> Map.merge(repo)
    |> Map.merge(extra)
  end

  defp environment(sink, extra) do
    Map.merge(
      %{
        "runtime" => "docker.runc.debian",
        "sink" => sink,
        "packages" => [],
        "preset" => "opencode",
        "executables" => [],
        "timeout_ms" => 1_000,
        "caches" => [],
        "mounts" => [],
        "policy" => %{"mode" => "off"},
        "network" => "none",
        "resources" => %{"cpus" => 1, "memory" => "1GB", "pids" => 32}
      },
      extra
    )
  end

  defp git!(path, args) do
    env = [
      {"GIT_AUTHOR_NAME", "t"},
      {"GIT_AUTHOR_EMAIL", "t@example.com"},
      {"GIT_COMMITTER_NAME", "t"},
      {"GIT_COMMITTER_EMAIL", "t@example.com"}
    ]

    {output, 0} = System.cmd("git", ["-C", path | args], env: env, stderr_to_stdout: true)
    String.trim(output)
  end
end
