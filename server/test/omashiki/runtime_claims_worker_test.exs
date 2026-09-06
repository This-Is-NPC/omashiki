defmodule Omashiki.Runtime.ClaimsWorkerTest do
  use ExUnit.Case, async: true

  alias Omashiki.Jobs.Job
  alias Omashiki.Runtime.Claims

  test "issues and verifies from in-memory job without Repo" do
    job = %Job{
      id: Ecto.UUID.generate(),
      user_id: Ecto.UUID.generate(),
      admitted_environment_digest: String.duplicate("a", 64),
      status: "running"
    }

    assert {:ok, token} = Claims.issue("egress", job, %{})
    assert {:ok, claims} = Claims.verify("egress", token)
    assert claims["job_id"] == job.id
  end
end
