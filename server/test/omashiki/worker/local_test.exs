defmodule Omashiki.Worker.LocalTest do
  use Omashiki.DataCase, async: false

  import Omashiki.JobFixtures

  alias Omashiki.Jobs
  alias Omashiki.Jobs.{Job, JobAttempt}
  alias Omashiki.Repo
  alias Omashiki.Worker.{Complete, Local, Offer}

  defmodule GitCompletingRunner do
    alias Omashiki.Jobs
    alias Omashiki.Jobs.JobAttempt
    alias Omashiki.Repo

    def run(%JobAttempt{} = attempt, _opts) do
      {:ok, _} =
        Jobs.complete(attempt, attempt.lease_token, "succeeded", %{
          branch: "omashiki/local-git",
          base_sha: String.duplicate("a", 40),
          head_sha: String.duplicate("b", 40),
          worktree_clean: true,
          result: %{"ok" => true}
        })

      {:ok, Repo.get!(Omashiki.Jobs.Job, attempt.job_id)}
    end
  end

  defmodule FilesCompletingRunner do
    alias Omashiki.Jobs
    alias Omashiki.Jobs.JobAttempt
    alias Omashiki.Repo

    def run(%JobAttempt{} = attempt, _opts) do
      {:ok, _} =
        Jobs.complete(attempt, attempt.lease_token, "succeeded", %{
          result: %{
            "job_id" => to_string(attempt.job_id),
            "changed_bytes" => 42,
            "blob_digest" => String.duplicate("c", 64),
            "blob_path" => "/tmp/local-blob",
            "sink" => "files"
          }
        })

      {:ok, Repo.get!(Omashiki.Jobs.Job, attempt.job_id)}
    end
  end

  defmodule NoneCompletingRunner do
    alias Omashiki.Jobs
    alias Omashiki.Jobs.JobAttempt
    alias Omashiki.Repo

    def run(%JobAttempt{} = attempt, _opts) do
      {:ok, _} =
        Jobs.complete(attempt, attempt.lease_token, "succeeded", %{
          result: %{
            "job_id" => to_string(attempt.job_id),
            "changed_bytes" => 7,
            "sink" => "none"
          }
        })

      {:ok, Repo.get!(Omashiki.Jobs.Job, attempt.job_id)}
    end
  end

  defmodule RefusingRunner do
    def run(%JobAttempt{}, _opts), do: {:error, :runner_refused}
  end

  setup do
    user = user_fixture()
    {token, _plaintext} = api_token_fixture(user)

    on_exit(fn ->
      Application.delete_env(:omashiki, :dispatch_attempt_runner)
    end)

    {:ok, user: user, token: token}
  end

  defp stub_runner(mod), do: Application.put_env(:omashiki, :dispatch_attempt_runner, mod)

  defp claim_offer(user, token, attrs) do
    {job, _attempt} = job_fixture(user, token, attrs)
    {:ok, attempt} = Jobs.claim(job.id, "local-test")
    job = Repo.get!(Job, job.id)
    offer = Offer.from_claimed(job, attempt)
    {offer, attempt}
  end

  test "execute/2 returns git complete for a git sink job", %{user: user, token: token} do
    stub_runner(GitCompletingRunner)
    {offer, _attempt} = claim_offer(user, token, %{})

    assert {:ok, %Complete{kind: :git, branch: "omashiki/local-git"}} =
             Local.execute(offer, [])
  end

  test "execute/2 returns files complete for a files sink job", %{user: user, token: token} do
    stub_runner(FilesCompletingRunner)

    {offer, _attempt} =
      claim_offer(user, token, %{
        repository: nil,
        admitted_repository: nil,
        admitted_repository_digest: nil,
        admitted_environment: %{"name" => "files-env", "sink" => "files"}
      })

    assert {:ok, %Complete{kind: :files, changed_bytes: 42, blob_digest: digest}} =
             Local.execute(offer, [])

    assert digest == String.duplicate("c", 64)
  end

  test "execute/2 returns none complete for a none sink job", %{user: user, token: token} do
    stub_runner(NoneCompletingRunner)

    {offer, _attempt} =
      claim_offer(user, token, %{
        repository: nil,
        admitted_repository: nil,
        admitted_repository_digest: nil,
        admitted_environment: %{"name" => "none-env", "sink" => "none"}
      })

    assert {:ok, %Complete{kind: :none, changed_bytes: 7}} = Local.execute(offer, [])
  end

  test "execute/2 passes through a refusing inner runner", %{user: user, token: token} do
    stub_runner(RefusingRunner)
    {offer, _attempt} = claim_offer(user, token, %{})

    assert {:error, :runner_refused} = Local.execute(offer, [])
  end
end
