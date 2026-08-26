defmodule Omashiki.Jobs.DispatchWorkerTest do
  @moduledoc """
  NFR-001 regression guard: a dispatch that ends in an Oban error must never
  leave the `jobs` row behind in a non-terminal state with `terminal_error`
  nil. Silent loss is the defect; a visible terminal row is the contract.
  """

  use Omashiki.DataCase, async: false
  use Oban.Testing, repo: Omashiki.Repo

  import Omashiki.JobFixtures

  alias Omashiki.Jobs
  alias Omashiki.Jobs.{DispatchWorker, ExecutionCapacity, Job, JobAttempt, JobEvent}
  alias Omashiki.Repo

  @moduletag :capture_log

  @non_terminal ~w(blocked queued provisioning running)

  defmodule NonTerminalRunner do
    @moduledoc "Runner that returns success without ever reaching a terminal job row."
    def run(%JobAttempt{job_id: job_id}, _opts \\ []),
      do: {:ok, Omashiki.Repo.get!(Omashiki.Jobs.Job, job_id)}
  end

  defmodule ErrorRunner do
    @moduledoc "Runner that fails without writing any terminal state itself."
    def run(%JobAttempt{}, _opts \\ []), do: {:error, :container_unavailable}
  end

  defmodule StartFailureRunner do
    @moduledoc "AttemptSupervisor could not start the attempt coordinator at all."
    def run(%JobAttempt{}, _opts \\ []), do: {:error, {:attempt_start_failed, :max_children}}
  end

  defmodule ProcessExitRunner do
    @moduledoc """
    The attempt coordinator died and `AttemptSupervisor.fail_if_active/2`
    could not fence it. That helper rescues and catches everything and
    returns `:ok` regardless, so the job row can outlive the crash untouched.
    """
    def run(%JobAttempt{}, _opts \\ []), do: {:error, {:attempt_process_exit, :killed}}
  end

  defmodule RaisingRunner do
    @moduledoc "Runner that blows up the way a serialization failure does under load."
    def run(%JobAttempt{}, _opts \\ []), do: raise("simulated dispatch crash")
  end

  defmodule SucceedingRunner do
    @moduledoc "Runner that drives the attempt all the way to a terminal job row."
    alias Omashiki.Jobs
    alias Omashiki.Jobs.{Job, JobAttempt}

    def run(%JobAttempt{} = attempt, _opts \\ []) do
      {:ok, _} =
        Jobs.complete(attempt, attempt.lease_token, "succeeded", %{
          branch: "omashiki/ok",
          base_sha: String.duplicate("1", 40),
          head_sha: String.duplicate("2", 40),
          worktree_clean: true,
          result: %{"ok" => true}
        })

      {:ok, Omashiki.Repo.get!(Job, attempt.job_id)}
    end
  end

  setup do
    user = user_fixture()
    {token, _plaintext} = api_token_fixture(user)
    on_exit(fn -> Application.delete_env(:omashiki, :dispatch_attempt_runner) end)
    {:ok, user: user, token: token}
  end

  defp stub_runner(mod), do: Application.put_env(:omashiki, :dispatch_attempt_runner, mod)

  defp max_attempts, do: DispatchWorker.__opts__()[:max_attempts]

  defp perform_final_attempt(job_id),
    do: perform_job(DispatchWorker, %{"job_id" => job_id}, attempt: max_attempts())

  defp exhaust_capacity!,
    do: Repo.update_all(ExecutionCapacity, set: [active: 8])

  test "runner returns a non-terminal result -> the job row never stays queued", %{
    user: user,
    token: token
  } do
    stub_runner(NonTerminalRunner)
    {job, _attempt} = job_fixture(user, token)

    perform_final_attempt(job.id)

    reloaded = Repo.get!(Job, job.id)

    refute reloaded.status in @non_terminal,
           "job was left at #{reloaded.status} with terminal_error #{inspect(reloaded.terminal_error)} after dispatch gave up"

    assert reloaded.terminal_error
    assert reloaded.finished_at
  end

  test "runner returns an error -> the job row reaches a terminal state", %{
    user: user,
    token: token
  } do
    stub_runner(ErrorRunner)
    {job, _attempt} = job_fixture(user, token)

    perform_final_attempt(job.id)

    reloaded = Repo.get!(Job, job.id)

    refute reloaded.status in @non_terminal
    assert reloaded.terminal_error
  end

  test "runner raises -> the job row reaches a terminal state instead of vanishing", %{
    user: user,
    token: token
  } do
    stub_runner(RaisingRunner)
    {job, _attempt} = job_fixture(user, token)

    perform_final_attempt(job.id)

    reloaded = Repo.get!(Job, job.id)

    refute reloaded.status in @non_terminal
    assert reloaded.terminal_error
  end

  test "AttemptSupervisor failing to start a coordinator still terminates the job row", %{
    user: user,
    token: token
  } do
    stub_runner(StartFailureRunner)
    {job, _attempt} = job_fixture(user, token)

    perform_final_attempt(job.id)

    reloaded = Repo.get!(Job, job.id)
    refute reloaded.status in @non_terminal
    assert reloaded.terminal_error["code"] == "dispatch_failed"
  end

  test "an unfenced attempt process exit still terminates the job row", %{
    user: user,
    token: token
  } do
    stub_runner(ProcessExitRunner)
    {job, _attempt} = job_fixture(user, token)

    perform_final_attempt(job.id)

    reloaded = Repo.get!(Job, job.id)
    refute reloaded.status in @non_terminal
    assert reloaded.terminal_error
  end

  test "a terminated dispatch emits a terminal event so operators can see it", %{
    user: user,
    token: token
  } do
    stub_runner(ErrorRunner)
    {job, _attempt} = job_fixture(user, token)

    perform_final_attempt(job.id)

    events = Repo.all(from(e in JobEvent, where: e.job_id == ^job.id, order_by: e.sequence))
    assert Enum.any?(events, &(&1.status in ~w(failed cancelled)))
  end

  test "capacity exhaustion still snoozes rather than burning the retry budget", %{
    user: user,
    token: token
  } do
    {job, _attempt} = job_fixture(user, token)
    exhaust_capacity!()

    assert {:snooze, 1} = perform_job(DispatchWorker, %{"job_id" => job.id})
    assert Repo.get!(Job, job.id).status == "queued"
  end

  test "a claimed attempt settles immediately, even on a non-final Oban attempt", %{
    user: user,
    token: token
  } do
    stub_runner(RaisingRunner)
    {job, _attempt} = job_fixture(user, token)

    # The claim already burnt the attempt: a retry would only ever see
    # `not_queued`, so waiting for the retry budget just delays the loss.
    assert {:error, _} = perform_job(DispatchWorker, %{"job_id" => job.id}, attempt: 1)

    reloaded = Repo.get!(Job, job.id)
    refute reloaded.status in @non_terminal
    assert reloaded.terminal_error["code"] == "dispatch_failed"
  end

  test "the worker keeps a retry budget above one attempt with growing backoff" do
    assert max_attempts() > 1

    backoffs = Enum.map(1..max_attempts(), &DispatchWorker.backoff(%Oban.Job{attempt: &1}))
    assert Enum.all?(backoffs, &(&1 > 0))
    assert List.last(backoffs) > List.first(backoffs)
  end

  test "a job row that already reached a terminal state is left untouched", %{
    user: user,
    token: token
  } do
    stub_runner(ErrorRunner)
    {job, _attempt} = job_fixture(user, token, %{status: "succeeded"})

    assert {:cancel, {:not_queued, "succeeded"}} = perform_final_attempt(job.id)

    reloaded = Repo.get!(Job, job.id)
    assert reloaded.status == "succeeded"
    refute reloaded.terminal_error
  end

  test "dispatch for a missing job row is cancelled, not retried" do
    assert {:cancel, :job_missing} =
             perform_job(DispatchWorker, %{"job_id" => Ecto.UUID.generate()})
  end

  test "a successful terminal run returns :ok and leaves the terminal row alone", %{
    user: user,
    token: token
  } do
    stub_runner(SucceedingRunner)
    {job, _attempt} = job_fixture(user, token)

    assert :ok = perform_final_attempt(job.id)
    assert Repo.get!(Job, job.id).status == "succeeded"
  end
end
