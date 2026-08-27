defmodule Omashiki.Runtime.ProvisionGenerationTest do
  @moduledoc """
  Provisioning points the harness at a model. This pins *which* model.

  A job can sit queued across a hot reload. `Jobs.Runner.DockerContainer` never
  passes `:credential`, so `do_provision_for_job/4` resolves it itself from the
  environment it was handed — which is `job.admitted_environment`, the capture
  taken at admission. Resolving it from the live generation instead would
  provision the job against configuration it was never admitted under, while
  its own `jobs` row and its `registry_digest` still say otherwise.

  ## Why this goes through `op_provision/4` rather than the helper

  A test that calls `Credentials.pin/1` directly proves the helper works and
  proves nothing about the path a job travels: reverting the production call
  site leaves it green. The credential is computed before the first Docker
  call and carried into `Harness.Context`, so a capturing adapter observes
  exactly what provisioning decided — no daemon required, and the linkage from
  caller to decision is inside the assertion.
  """

  use Omashiki.DataCase, async: false

  alias Omashiki.Config
  alias Omashiki.Harness.LaunchPlan
  alias Omashiki.Plugin.Preset
  alias Omashiki.Jobs.Admission
  alias Omashiki.Repo
  alias Omashiki.Runtime.ContainerManager
  alias Omashiki.Isolation

  # Returns an error so provisioning stops here: what is being tested happened
  # before this was reached.
  defmodule CapturingAdapter do
    @behaviour Omashiki.Harness.Adapter

    @impl true
    def validate_options(_manifest, _options), do: :ok

    @impl true
    def launch_plan(_spec), do: {:error, :not_used}

    @impl true
    def prepare(_spec, context) do
      send(owner(), {:provisioned_with, context.credential})
      {:error, :captured}
    end

    @impl true
    def invoke(_invocation, _context), do: {:error, :not_used}

    def own(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)
    defp owner, do: :persistent_term.get({__MODULE__, :owner})
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "omashiki-provision-#{System.unique_integer([:positive])}")

    repo_path = Path.join(root, "repo")
    File.mkdir_p!(repo_path)
    {_output, 0} = System.cmd("git", ["-C", repo_path, "init", "-q"])

    load_config = fn model ->
      Config.load_map!(config_map(model), path: Path.join(root, "omashiki.toml"))
    end

    load_config.("admitted-model")
    CapturingAdapter.own(self())

    user = user_fixture()
    {token, _plaintext} = api_token_fixture(user)

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, token: token, repo_path: repo_path, load_config: load_config}
  end

  test "a job queued across a hot swap is provisioned with the model it was admitted with",
       %{token: token, repo_path: repo_path, load_config: load_config} do
    assert {:ok, job} = Admission.admit(token, request())
    assert [%{"model" => "admitted-model"}] = job.admitted_environment["credentials"]

    # The operator swaps the model while the job is still queued.
    load_config.("swapped-after-admission")
    assert %{model: "swapped-after-admission"} = Config.get_credential("secret")

    provision(job, repo_path)

    assert_receive {:provisioned_with, credential}, 1_000
    assert credential.model == "admitted-model"

    # The key is deliberately *not* pinned: admission strips it so it never
    # reaches a database column, so it can only come from the live generation.
    assert credential.api_key == "do-not-persist"
  end

  test "a job admitted after the swap is provisioned with the new model",
       %{token: token, repo_path: repo_path, load_config: load_config} do
    load_config.("swapped-before-admission")
    assert {:ok, job} = Admission.admit(token, request())

    provision(job, repo_path)

    assert_receive {:provisioned_with, credential}, 1_000
    assert credential.model == "swapped-before-admission"
  end

  # `Jobs.Runner.DockerContainer.provision/4` passes `:worktree_path` and
  # `:preset` and nothing else. If it ever started passing
  # `:credential`, line 269 would short-circuit and the pin would stop being
  # reachable — so the production caller's option set is part of the contract.
  defp provision(job, repo_path) do
    attempt = Repo.get_by!(Omashiki.Jobs.JobAttempt, job_id: job.id)

    ContainerManager.op_provision(job, attempt, job.admitted_environment,
      worktree_path: repo_path,
      preset: profile()
    )
  end

  defp profile do
    runtime = %Isolation{
      key: "opencode",
      kind: "docker",
      config: %{"image" => "agent:latest"},
      status: "active"
    }

    %Preset{
      name: "opencode",
      adapter: CapturingAdapter,
      adapter_key: "opencode",
      options: %{},
      runtime: runtime,
      # "stdio" rather than "http" so provisioning does not reserve a host port
      # on the way to the decision under test.
      launch_plan: %LaunchPlan{
        runtime: runtime,
        transport: %{"kind" => "stdio"},
        startup: nil,
        readiness: nil,
        secret: nil,
        environment: []
      },
      manifest: nil
    }
  end

  defp request do
    %{
      "schema_version" => 1,
      "idempotency_key" => "provision-#{System.unique_integer([:positive])}",
      "correlation_id" => "provision-corr",
      "repo" => "app",
      "environment" => "safe",
      "payload" => %{"instruction" => "run"},
      "priority" => 1
    }
  end

  defp config_map(model) do
    %{
      "repositories" => %{"app" => %{"path" => "repo", "base_branch" => "main"}},
      "presets" => %{
          "opencode" => %{"plugin" => "opencode", "options" => %{}}
        },
      "credentials" => %{
        "secret" => %{
          "provider" => "anthropic",
          "model" => model,
          "api_key" => "do-not-persist"
        }
      },
      "environments" => %{
        "safe" => %{
          "isolation" => "docker",
          "image" => "omashiki/agent:latest",
          "sink" => "git",
          "packages" => [],
          "preset" => "opencode",
          "executables" => ["git"],
          "credentials" => ["secret"],
          "timeout_ms" => 1_000,
          "caches" => [],
          "mounts" => [],
          "pre_steps" => [],
          "post_steps" => [],
          "policy" => %{"mode" => "off"},
          "network" => "none",
          "resources" => %{"cpus" => 1, "memory" => "1GB", "pids" => 32}
        }
      },
      "limits" => %{}
    }
  end
end
