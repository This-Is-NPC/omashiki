defmodule Omashiki.DoctorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Omashiki.Config.{HostCredential, Identity}
  alias Omashiki.Doctor
  alias Omashiki.Doctor.{FakeProbe, Monitor}

  setup do
    previous =
      for key <- [:agent_network_mode, :restricted_agent_network],
          do: {key, Application.fetch_env(:omashiki, key)}

    Application.delete_env(:omashiki, :agent_network_mode)
    Application.put_env(:omashiki, :restricted_agent_network, "omashiki-agents")

    on_exit(fn ->
      FakeProbe.reset()

      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:omashiki, key, value)
          :error -> Application.delete_env(:omashiki, key)
        end
      end
    end)
  end

  test "a Docker that does not answer skips every Docker check" do
    FakeProbe.set(%{runtime: {:error, :econnrefused}})

    checks = run(environments: [environment("opencode", "restricted", "agent:1")], route: true)

    assert [%{status: :error, fix: fix}] = Enum.filter(checks, &(&1.id == "docker"))
    assert fix =~ "Start Docker"

    refute Enum.any?(
             checks,
             &String.starts_with?(&1.id, ["image:", "network:", "route:"])
           )
  end

  test "a missing image names the environments it stops and how to build it" do
    FakeProbe.set(%{
      image: fn
        "agent:missing" -> {:error, :not_found}
        _image -> :ok
      end
    })

    checks =
      run(
        install: :checkout,
        environments: [
          environment("codex", "none", "agent:missing"),
          environment("opencode", "none", "agent:missing"),
          environment("pi", "none", "agent:present")
        ]
      )

    assert %{status: :error, summary: summary, fix: fix} = find(checks, "image:agent:missing")
    assert summary =~ "environments codex, opencode"
    assert fix =~ "mise run images"
    assert fix =~ "docker pull agent:missing"
    assert %{status: :ok} = find(checks, "image:agent:present")
  end

  test "a release builds a missing image from the repository at its own version" do
    FakeProbe.set(%{image: {:error, :not_found}})

    checks =
      run(install: :release, environments: [environment("opencode", "none", "agent:missing")])

    assert %{status: :error, fix: fix} = find(checks, "image:agent:missing")
    vsn = Application.spec(:omashiki, :vsn)

    assert fix =~
             "`docker build -t agent:missing " <>
               "\"https://github.com/This-Is-NPC/omashiki.git#v#{vsn}:agent\"`"

    assert fix =~ "Omashiki never pulls images"
    assert fix =~ "docker pull agent:missing"
    refute fix =~ "mise"
  end

  test "a restricted environment without an agent network is an error" do
    Application.delete_env(:omashiki, :restricted_agent_network)

    checks = run(environments: [environment("opencode", "restricted", "agent:1")])

    assert %{status: :error, summary: summary, fix: fix} = find(checks, "network:opencode")
    assert summary =~ "harness_unreachable_no_network"
    assert fix =~ "OMASHIKI_AGENT_NETWORK_MODE"
  end

  test "a restricted environment checks the network it resolves to" do
    FakeProbe.set(%{network: fn "omashiki-agents" -> {:error, :not_found} end})

    checks =
      run(
        environments: [
          environment("opencode", "restricted", "agent:1"),
          environment("offline", "none", "agent:1")
        ]
      )

    assert %{status: :error, fix: fix} = find(checks, "network:opencode")
    assert fix =~ "docker network create omashiki-agents"
    refute find(checks, "network:offline")
  end

  test "the route check runs only when asked, from a present image" do
    test_pid = self()

    FakeProbe.set(%{
      route: fn image, network, url ->
        send(test_pid, {:route, image, network, url})
        :ok
      end
    })

    environments = [environment("opencode", "restricted", "agent:1")]

    refute find(run(environments: environments), "route:omashiki-agents")
    refute_received {:route, _, _, _}

    checks =
      run(environments: environments, route: true, house_url: "http://omashiki:4000")

    assert %{status: :ok} = find(checks, "route:omashiki-agents")

    assert_received {:route, "agent:1", "omashiki-agents", "http://omashiki:4000/api/v1/health"}
  end

  test "a route blocked through the host names the port and the host firewall" do
    FakeProbe.set(%{route: {:error, {:blocked, [to_house: {:exit, 1}]}}})

    checks =
      run(
        environments: [environment("opencode", "restricted", "agent:1")],
        route: true,
        house_url: "http://host.docker.internal:4010"
      )

    assert %{status: :error, summary: summary, fix: fix} = find(checks, "route:omashiki-agents")
    assert summary =~ "timeout without tools"
    assert fix =~ "port 4010"
    assert fix =~ "ufw"
  end

  test "a route blocked on a shared network names the house URL setting" do
    FakeProbe.set(%{route: {:error, {:blocked, [to_house: {:exit, 1}]}}})

    checks =
      run(
        environments: [environment("opencode", "restricted", "agent:1")],
        route: true,
        house_url: "http://omashiki:4000"
      )

    assert %{status: :error, fix: fix} = find(checks, "route:omashiki-agents")
    assert fix =~ "OMASHIKI_HOUSE_URL"
    refute fix =~ "ufw"
  end

  test "a house that cannot reach the agent network says jobs fail and how to attach it" do
    FakeProbe.set(%{route: {:error, {:blocked, [from_house: :etimedout]}}})

    checks =
      run(environments: [environment("opencode", "restricted", "agent:1")], route: true)

    assert %{status: :error, summary: summary, fix: fix} = find(checks, "route:omashiki-agents")
    assert summary =~ "The house cannot reach containers on network omashiki-agents"
    assert summary =~ "harness_not_ready"
    assert fix =~ "Attach the house container to network omashiki-agents"
  end

  test "an image without python3 leaves the route unchecked" do
    FakeProbe.set(%{route: {:error, :no_python}})

    checks =
      run(environments: [environment("opencode", "restricted", "agent:1")], route: true)

    assert %{status: :warn, summary: summary} = find(checks, "route:omashiki-agents")
    assert summary =~ "no python3"
  end

  test "the route is not blamed while the house itself does not answer" do
    FakeProbe.set(%{
      house: {:error, :econnrefused},
      route: fn _, _, _ -> flunk("route probed without a house") end
    })

    [checkout, release] =
      for install <- [:checkout, :release] do
        checks =
          run(
            install: install,
            environments: [environment("opencode", "restricted", "agent:1")],
            route: true
          )

        assert %{status: :warn, fix: fix} = find(checks, "route:omashiki-agents")
        fix
      end

    assert checkout =~ "`mise run up`, then run `mise run doctor` again"
    assert release =~ "`docker compose up -d`, then run `bin/doctor` again"
    refute release =~ "mise"
  end

  test "the route check never pulls: no present image is a warning" do
    FakeProbe.set(%{image: {:error, :not_found}})

    checks =
      run(environments: [environment("opencode", "restricted", "agent:1")], route: true)

    assert %{status: :warn, fix: fix} = find(checks, "route:omashiki-agents")
    assert fix =~ "the image checks name"
  end

  test "an unreadable host credential is an error when an environment uses it" do
    used = host_credential("opencode-local", "opencode")
    unused = host_credential("claude-local", "claude-code")
    FakeProbe.set(%{readable: {:error, :enoent}})

    checks =
      run(
        environments: [environment("opencode", "none", "agent:1", [used])],
        host_credentials: [used, unused]
      )

    assert %{status: :error, summary: summary, fix: fix} =
             find(checks, "host-credential:opencode-local")

    assert summary =~ "auth.json"
    refute summary =~ "/home/operator"
    assert fix =~ "[host_credentials.opencode-local]"
    assert %{status: :warn} = find(checks, "host-credential:claude-local")
  end

  test "an unreadable host credential names the login in a checkout and the mount in a release" do
    credential = host_credential("opencode-local", "opencode")
    FakeProbe.set(%{readable: {:error, :enoent}})

    [checkout, release] =
      for install <- [:checkout, :release] do
        checks = run(install: install, host_credentials: [credential])
        find(checks, "host-credential:opencode-local").fix
      end

    assert checkout =~ "Log in with opencode on this machine"
    refute checkout =~ "Mount"

    assert release =~ "Mount the directory of each origin read-only into the house container"

    assert release =~
             "/blob/v#{Application.spec(:omashiki, :vsn)}/docs/how-to-configure-model-access.md" <>
               "#mount-the-origins-into-a-container"

    assert release =~ "[host_credentials.opencode-local]"
  end

  test "a readable host credential is ok" do
    credential = host_credential("opencode-local", "opencode")

    assert %{status: :ok} =
             find(run(host_credentials: [credential]), "host-credential:opencode-local")
  end

  test "a directory the house writes to is ok when the house can write there" do
    checks = run(directories: [{"cache", "/home/operator/.cache/omashiki"}])

    assert %{status: :ok, summary: summary} = find(checks, "directory:cache")
    assert summary =~ "/home/operator/.cache/omashiki"
  end

  test "a missing directory the house can create on first use is ok" do
    FakeProbe.set(%{
      directory: fn
        "/home/operator/.local/state/omashiki" -> {:error, :enoent}
        "/home/operator/.local/state" -> {:error, :enoent}
        "/home/operator/.local" -> :ok
      end
    })

    directories = [{"state", "/home/operator/.local/state/omashiki"}]

    for install <- [:checkout, :release] do
      assert %{status: :ok, summary: summary} =
               find(run(install: install, directories: directories), "directory:state")

      assert summary =~ "creates /home/operator/.local/state/omashiki for cache use records"
    end
  end

  test "a missing directory the house cannot create is created for its account" do
    FakeProbe.set(%{
      directory: fn
        "/home/operator/.local/state/omashiki" -> {:error, :enoent}
        "/home/operator/.local/state" -> {:error, :eacces}
      end
    })

    directories = [{"state", "/home/operator/.local/state/omashiki"}]

    [checkout, release] =
      for install <- [:checkout, :release] do
        assert %{status: :error, summary: summary, fix: fix} =
                 find(run(install: install, directories: directories), "directory:state")

        assert summary =~ "/home/operator/.local/state/omashiki does not exist"
        assert summary =~ "cannot create it in /home/operator/.local/state (:eacces)"
        assert summary =~ "cache use records"
        fix
      end

    command =
      "`sudo mkdir -p /home/operator/.local/state/omashiki && " <>
        "sudo chown -R $(id -u):$(id -g) /home/operator/.local/state/omashiki`"

    assert checkout =~ "Run #{command} as the account"

    assert release =~ "On the host, run #{command}"
    assert release =~ "`docker compose restart omashiki`"

    assert release =~
             "/blob/v#{Application.spec(:omashiki, :vsn)}/docs/how-to-install-from-the-image.md" <>
               "#1-download-the-files"

    refute release =~ "mise"
  end

  test "a directory the house cannot write to is given to its account" do
    FakeProbe.set(%{directory: {:error, :eacces}})

    checks =
      run(
        install: :release,
        directories: [
          {"work", "/home/operator/.cache/omashiki/tmp/omashiki"},
          {"config", "/config"},
          {"credentials", "/dev/shm"}
        ]
      )

    assert %{status: :error, summary: summary, fix: work} = find(checks, "directory:work")
    assert summary =~ "cannot write to /home/operator/.cache/omashiki/tmp/omashiki (:eacces)"
    assert work =~ "`sudo chown -R $(id -u):$(id -g) /home/operator/.cache/omashiki/tmp/omashiki`"

    # Compose mounts the configuration directory at /config, not at its host path.
    assert %{status: :error, fix: config} = find(checks, "directory:config")
    assert config =~ "In the host directory mounted at /config"
    assert config =~ "`sudo chown -R $(id -u):$(id -g) .`"

    # Every user's house creates its own entries in /dev/shm: never chown it.
    assert %{status: :error, fix: credentials} = find(checks, "directory:credentials")
    assert credentials =~ "`sudo chmod 1777 /dev/shm`"
  end

  test "the work directory is TMPDIR as set, even when the VM would fall back" do
    previous = System.get_env("TMPDIR")

    refused = "/home/operator/.cache/omashiki/tmp/omashiki"
    System.put_env("TMPDIR", refused)

    on_exit(fn ->
      if previous, do: System.put_env("TMPDIR", previous), else: System.delete_env("TMPDIR")
    end)

    FakeProbe.set(%{
      directory: fn path -> if path == refused, do: {:error, :eacces}, else: :ok end
    })

    checks = Doctor.run(probe: FakeProbe, environments: [], host_credentials: [], identities: [])

    assert %{status: :error, summary: summary} = find(checks, "directory:work")
    assert summary =~ refused

    for id <- ["cache", "state", "config", "credentials"],
        do: assert(%{status: :ok} = find(checks, "directory:#{id}"))
  end

  test "each identity must mint an installation token" do
    FakeProbe.set(%{
      identity: fn
        %{name: "ana-bot"} -> :ok
        %{name: "old-bot"} -> {:error, {:installation_token_http, 401}}
      end
    })

    checks = run(identities: [identity("ana-bot"), identity("old-bot")])

    assert %{status: :ok} = find(checks, "identity:ana-bot")
    assert %{status: :error, fix: fix} = find(checks, "identity:old-bot")
    assert fix =~ "[identities.old-bot]"
  end

  test "gitleaks must run, or output that needs scanning is refused" do
    assert %{status: :ok} = find(run([]), "gitleaks")

    FakeProbe.set(%{secret_scanner: {:error, :not_found}})

    assert %{status: :error, summary: summary, fix: fix} =
             find(run(install: :checkout), "gitleaks")

    assert summary =~ "secret_scan_unavailable"
    assert fix =~ "mise install"

    assert %{fix: fix} = find(run(install: :release), "gitleaks")
    assert fix =~ "Omashiki image"
  end

  test "worst/1 ranks error over warn over ok" do
    assert Doctor.worst([]) == :ok
    assert Doctor.worst([%{status: :ok}, %{status: :warn}]) == :warn
    assert Doctor.worst([%{status: :warn}, %{status: :error}]) == :error
  end

  describe "Monitor" do
    test "runs the full doctor at boot, logs only problems, and keeps the route" do
      FakeProbe.set(%{route: {:error, {:blocked, [to_house: {:exit, 1}]}}})
      doctor = [probe: FakeProbe, environments: [environment("opencode", "restricted", "a:1")]]

      log =
        capture_log(fn ->
          monitor = start_supervised!({Monitor, name: nil, boot: true, doctor: doctor})
          %{checks: checks} = Monitor.refresh(monitor)
          assert %{status: :error} = find(checks, "route:omashiki-agents")

          FakeProbe.set(%{})
          %{checks: checks, checked_at: %DateTime{}} = Monitor.refresh(monitor)
          assert %{status: :error} = find(checks, "route:omashiki-agents")
          assert %{status: :ok} = find(checks, "network:opencode")
        end)

      assert log =~ "timeout without tools"
      refute log =~ "Docker answers"
    end

    test "is empty until a run finishes" do
      monitor = start_supervised!({Monitor, name: nil, boot: false})
      assert %{checks: [], checked_at: nil} = Monitor.latest(monitor)
    end
  end

  defp run(opts) do
    Doctor.run(
      Keyword.merge(
        [
          probe: FakeProbe,
          environments: [],
          host_credentials: [],
          identities: [],
          directories: []
        ],
        opts
      )
    )
  end

  defp find(checks, id), do: Enum.find(checks, &(&1.id == id))

  defp environment(name, network, image, host_credentials \\ []) do
    %{name: name, network: network, runtime: %{image: image}, host_credentials: host_credentials}
  end

  defp host_credential(name, kind) do
    %HostCredential{name: name, kind: kind, files: %{"auth.json" => "/home/operator/auth.json"}}
  end

  defp identity(name) do
    %Identity{
      name: name,
      kind: "github-app",
      app_id: "1",
      installation_id: "2",
      private_key: "unused"
    }
  end
end
