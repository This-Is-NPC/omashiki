defmodule Omashiki.Gateway.BudgetTest do
  @moduledoc """
  The budget guard must **enforce**, not advise. An advisory budget is the
  worst of both worlds: it reads as a control in the config file and spends
  without limit at runtime.
  """

  use Omashiki.DataCase, async: false

  alias Omashiki.Gateway.Budget
  alias Omashiki.Jobs.Job
  alias Omashiki.UsageLedger

  setup do
    :ok
  end

  describe "check/1 with a per-job ceiling" do
    test "a job with no declared budget is unlimited" do
      job = job_fixture()
      spend(job, 1, input: 1_000_000, output: 1_000_000)

      assert Budget.check(job) == :ok
    end

    test "spend below the ceiling is allowed" do
      job = job_fixture(%{"budget_tokens" => 100})
      spend(job, 1, input: 40, output: 40)

      assert Budget.check(job) == :ok
    end

    test "spend at the ceiling is refused — the cap is inclusive" do
      job = job_fixture(%{"budget_tokens" => 100})
      spend(job, 1, input: 60, output: 40)

      assert Budget.check(job) == {:error, :budget_exceeded}
    end

    test "spend over the ceiling is refused" do
      job = job_fixture(%{"budget_tokens" => 100})
      spend(job, 1, input: 90, output: 30)

      assert Budget.check(job) == {:error, :budget_exceeded}
    end

    test "cache-write tokens count against the ceiling" do
      job = job_fixture(%{"budget_tokens" => 100})
      spend(job, 1, input: 10, output: 10, cache_write: 90)

      assert Budget.check(job) == {:error, :budget_exceeded}
    end

    test "another job's spend does not consume this job's ceiling" do
      job = job_fixture(%{"budget_tokens" => 100})
      other = job_fixture(%{"budget_tokens" => 100})
      spend(other, 1, input: 500, output: 500)

      assert Budget.check(job) == :ok
    end

    test "a non-integer ceiling is ignored rather than crashing the turn" do
      job = job_fixture(%{"budget_tokens" => "one hundred"})
      spend(job, 1, input: 500, output: 500)

      assert Budget.check(job) == :ok
    end

    test "a job with a nil payload is handled" do
      job = job_fixture() |> Map.put(:payload, nil)

      assert Budget.check(job) == :ok
    end
  end

  describe "check/1 with the global ceiling" do
    test "global spend across all jobs is enforced even without a job budget" do
      job = job_fixture()
      other = job_fixture()
      spend(other, 1, input: 400, output: 400)
      spend(job, 1, input: 100, output: 100)

      merge_config!(%{"limits" => %{"global_budget_tokens" => 1_000}})

      assert Budget.check(job) == {:error, :budget_exceeded}
    end

    test "under the global ceiling the turn proceeds" do
      job = job_fixture()
      spend(job, 1, input: 100, output: 100)

      merge_config!(%{"limits" => %{"global_budget_tokens" => 1_000}})

      assert Budget.check(job) == :ok
    end

    test "spend outside the rolling window does not count toward the global cap" do
      job = job_fixture()
      old = DateTime.add(DateTime.utc_now(), -25 * 3600, :second)

      spend(job, 1, input: 500, output: 500, occurred_at: old)
      spend(job, 2, input: 100, output: 100)

      merge_config!(%{
        "limits" => %{"global_budget_tokens" => 1_000, "global_budget_window_hours" => 24}
      })

      assert Budget.spent_global() == 200
      assert Budget.check(job) == :ok
    end
  end

  describe "check/1 by job id" do
    test "an unknown job id is not billed to anyone" do
      assert Budget.check(Ecto.UUID.generate()) == :ok
    end

    test "a known job id resolves to the same decision as the struct" do
      job = job_fixture(%{"budget_tokens" => 10})
      spend(job, 1, input: 10, output: 0)

      assert Budget.check(job.id) == {:error, :budget_exceeded}
      assert Budget.check(job.id) == Budget.check(job)
    end
  end

  describe "spend accounting" do
    test "an unknown cache-write column never invents zero spend" do
      job = job_fixture()
      spend(job, 1, input: 10, output: 10)
      spend(job, 2, input: 10, output: 10, cache_write: 5)

      # SUM skips SQL NULL: turn 1's unknown cache contributes nothing, it does
      # not assert "zero cache was written".
      assert Budget.spent_for_job(job.id) == 45
    end

    test "a job with no ledger rows has spent nothing" do
      job = job_fixture()
      assert Budget.spent_for_job(job.id) == 0
    end

    test "global spend is the sum across jobs" do
      a = job_fixture()
      b = job_fixture()
      spend(a, 1, input: 10, output: 5)
      spend(b, 1, input: 20, output: 5, cache_write: 3)

      assert Budget.spent_global() == Budget.spent_for_job(a.id) + Budget.spent_for_job(b.id)
      assert Budget.spent_global() == 43
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp spend(%Job{id: job_id}, turn, opts) do
    {:ok, _} =
      UsageLedger.record(%{
        request_id: "budget-test:#{job_id}:#{turn}",
        job_id: job_id,
        turn: turn,
        source: "gateway",
        provider: "openai",
        model: "gpt-5-mini",
        input_tokens: Keyword.fetch!(opts, :input),
        output_tokens: Keyword.fetch!(opts, :output),
        cache_write_tokens: Keyword.get(opts, :cache_write),
        occurred_at: Keyword.get(opts, :occurred_at, DateTime.utc_now(:microsecond))
      })
  end

  defp job_fixture(payload_extra \\ %{}) do
    user = user_fixture()
    n = System.unique_integer([:positive])

    %Job{}
    |> Job.changeset(%{
      user_id: user.id,
      schema_version: 1,
      idempotency_key: "budget-#{n}",
      correlation_id: "budget-corr-#{n}",
      repository: "repo",
      environment: "agentic",
      payload: Map.merge(%{"instruction" => "work"}, payload_extra),
      payload_hash: String.duplicate("a", 64),
      admitted_repository: %{"path" => "/tmp/repo"},
      admitted_repository_digest: String.duplicate("b", 64),
      admitted_environment: %{"name" => "agentic"},
      admitted_environment_digest: String.duplicate("c", 64),
      admitted_plugin: %{"path" => "plugins/opencode.toml", "contents" => "", "digest" => String.duplicate("e", 64)},
      admitted_plugin_digest: String.duplicate("e", 64),
      registry_digest: String.duplicate("d", 64),
      queue: "default",
      priority: 1,
      status: "running",
      current_attempt: 1,
      queued_at: DateTime.utc_now(:microsecond),
      started_at: DateTime.utc_now(:microsecond)
    })
    |> Repo.insert!()
  end
end
