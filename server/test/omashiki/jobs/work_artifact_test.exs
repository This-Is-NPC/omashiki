defmodule Omashiki.Jobs.WorkArtifactTest do
  use ExUnit.Case, async: true

  alias Omashiki.Jobs.{Job, WorkArtifact}

  test "provision uses manager-scoped work directory" do
    job = %Job{id: "job-123"}
    opts = [manager_id: "mgr-a"]

    assert {:ok, artifact} =
             WorkArtifact.provision(job, "none", opts, fn art ->
               {:ok, art}
             end)

    assert String.ends_with?(artifact.path, Path.join(["omashiki-work", "mgr-a", "job-123"]))
    :ok = WorkArtifact.cleanup(artifact)
  end
end
