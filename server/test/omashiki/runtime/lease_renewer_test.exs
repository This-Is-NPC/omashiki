defmodule Omashiki.Runtime.LeaseRenewerTest do
  use Omashiki.DataCase, async: false

  alias Omashiki.Config
  alias Omashiki.Jobs
  alias Omashiki.Jobs.JobAttempt
  alias Omashiki.Runtime.LeaseRenewer

  setup do
    root = Path.join(System.tmp_dir!(), "omashiki-lease-#{System.unique_integer([:positive])}")
    repo_path = Path.join(root, "repo")
    File.mkdir_p!(repo_path)
    {_, 0} = System.cmd("git", ["-C", repo_path, "init", "-q"])

    Config.load_map!(
      %{
        "repositories" => %{"app" => %{"path" => "repo", "base_branch" => "main"}},
        "presets" => %{
          "opencode" => %{"plugin" => "opencode", "options" => %{}}
        },
        "runtimes" => %{
          "docker" => %{
            "runc" => %{"debian" => %{"images" => %{"opencode" => "omashiki/agent:latest"}}}
          }
        },
        "environments" => %{
          "safe" => %{
            "runtime" => "docker.runc.debian",
            "sink" => "git",
            "packages" => [],
            "preset" => "opencode",
            "executables" => ["git"],
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
      },
      path: Path.join(root, "omashiki.toml")
    )

    user = user_fixture()
    {token, _plaintext} = api_token_fixture(user)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, token: token}
  end

  test "renews every tracked lease in one tick", %{token: token} do
    attempts = Enum.map(1..3, &claim!(token, "renew-#{&1}"))
    before = Map.new(attempts, &{&1.id, &1.lease_expires_at})

    renewer = start_renewer!()
    Enum.each(attempts, &LeaseRenewer.register(renewer, &1.id, &1.lease_token))
    send(renewer, :renew)

    for attempt <- attempts do
      assert eventually(fn ->
               reloaded = Repo.get!(JobAttempt, attempt.id)

               DateTime.compare(reloaded.lease_expires_at, before[attempt.id]) == :gt and
                 not is_nil(reloaded.heartbeat_at)
             end),
             "lease for #{attempt.id} was not renewed"
    end
  end

  test "tells the owner when a lease is no longer its own", %{token: token} do
    attempt = claim!(token, "fenced")

    renewer = start_renewer!()
    LeaseRenewer.register(renewer, attempt.id, "not-the-lease-token")
    send(renewer, :renew)

    assert_receive {:lease_lost, id}, 2_000
    assert id == attempt.id

    # The renewer stops tracking it, so the message arrives exactly once.
    send(renewer, :renew)
    refute_receive {:lease_lost, ^id}, 300
  end

  test "an unregistered attempt is neither renewed nor reported", %{token: token} do
    attempt = claim!(token, "unregistered")
    expires_at = attempt.lease_expires_at

    renewer = start_renewer!()
    LeaseRenewer.register(renewer, attempt.id, attempt.lease_token)
    LeaseRenewer.unregister(renewer, attempt.id)
    send(renewer, :renew)

    refute_receive {:lease_lost, _}, 300
    assert Repo.get!(JobAttempt, attempt.id).lease_expires_at == expires_at
  end

  # The tick is driven by hand: a wall-clock interval would make these tests
  # race the scheduler instead of asserting the batch statement.
  defp start_renewer! do
    {:ok, pid} =
      start_supervised(
        {LeaseRenewer,
         name: :"lease_renewer_#{System.unique_integer([:positive])}",
         interval_ms: 60_000,
         lease_ms: 300_000},
        restart: :temporary
      )

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    pid
  end

  defp claim!(token, key) do
    {:ok, job} = Jobs.Admission.admit(token, request(key))
    {:ok, attempt} = Jobs.claim(job, "lease-runner-#{key}")
    attempt
  end

  defp eventually(fun, attempts \\ 40) do
    cond do
      fun.() -> true
      attempts <= 1 -> false
      true -> Process.sleep(25) && eventually(fun, attempts - 1)
    end
  end

  defp request(key) do
    %{
      "schema_version" => 1,
      "idempotency_key" => key,
      "correlation_id" => "correlation-#{key}",
      "repo" => "app",
      "environment" => "safe",
      "payload" => %{
        "instruction" => "run",
        "context" => %{"key" => key},
        "branch" => "feat-#{key}"
      },
      "priority" => 0
    }
  end
end
