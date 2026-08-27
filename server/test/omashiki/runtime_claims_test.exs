defmodule Omashiki.Runtime.ClaimsTest do
  use Omashiki.DataCase, async: false

  alias Omashiki.Jobs.Job
  alias Omashiki.Runtime.Claims
  alias Omashiki.Tools.McpConfig

  test "signed claims bind the job owner and environment without legacy identities" do
    job = job_fixture()
    assert {:ok, token} = Claims.issue("gateway", job, %{credential: "host-openai"})
    assert {:ok, claims} = Claims.verify("gateway", token)

    assert claims["job_id"] == job.id
    assert claims["token_owner"] == job.user_id
    assert claims["admitted_environment_digest"] == job.admitted_environment_digest
    assert claims["credential"] == "host-openai"
    refute Map.has_key?(claims, "task_id")
    refute Map.has_key?(claims, "api_key")
  end

  test "tampered and cross-environment claims fail closed" do
    job = job_fixture()
    assert {:ok, token} = Claims.issue("tools", job)
    assert {:error, :invalid} = Claims.verify("tools", token <> "tampered")

    {:ok, claims} = Claims.verify("tools", token)

    other_job = job_fixture()

    assert {:error, :owner_mismatch} =
             Claims.authorize("tools", Map.put(claims, "job_id", other_job.id))

    assert {:error, :environment_changed} =
             Claims.authorize("tools", Map.put(claims, "admitted_environment_digest", "stale"))
  end

  test "inactive jobs cannot mint runtime claims" do
    job = %{job_fixture() | status: "succeeded"}
    assert {:error, :job_not_active} = Claims.issue("egress", job)
  end

  test "MCP rendering exposes only environment-declared runtime servers" do
    job = job_fixture()

    rendered =
      McpConfig.render(job.admitted_environment, nil, %{
        token: "signed-runtime-token",
        base_url: "http://proxy.test"
      })

    assert Map.has_key?(rendered["mcp"], "internal")

    assert get_in(rendered, ["mcp", "internal", "headers", "Authorization"]) ==
             "Bearer signed-runtime-token"
  end

  test "public planning MCP is not mounted in the runtime router" do
    refute Enum.any?(OmashikiWeb.Router.__routes__(), &(&1.path == "/api/v1/mcp"))
  end

  defp job_fixture do
    user = user_fixture()

    attrs = %{
      user_id: user.id,
      schema_version: 1,
      idempotency_key: "claims-#{System.unique_integer([:positive])}",
      correlation_id: "claims-correlation",
      repository: "repo",
      environment: "isolated",
      payload: %{"ok" => true},
      payload_hash: String.duplicate("a", 64),
      admitted_repository: %{"path" => "/tmp/repo", "base_branch" => "main"},
      admitted_repository_digest: String.duplicate("b", 64),
      admitted_environment: %{
        "credentials" => [%{"name" => "host-openai"}],
        "capabilities" => ["internal_read"],
        "mcp_servers" => %{
          "internal" => %{"url" => "https://tools.example.test/mcp", "headers" => %{}}
        }
      },
      admitted_environment_digest: String.duplicate("c", 64),
      admitted_plugin: %{"path" => "plugins/opencode.toml", "contents" => "", "digest" => String.duplicate("e", 64)},
      admitted_plugin_digest: String.duplicate("e", 64),
      registry_digest: String.duplicate("d", 64),
      queue: "default",
      priority: 0,
      status: "running",
      current_attempt: 1,
      queued_at: DateTime.utc_now(:microsecond),
      started_at: DateTime.utc_now(:microsecond)
    }

    Repo.insert!(Job.changeset(%Job{}, attrs))
  end
end
