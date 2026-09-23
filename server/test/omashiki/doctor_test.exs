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

    assert [%{id: "docker", status: :error, fix: fix}] =
             run(environments: [environment("opencode", "restricted", "agent:1")], route: true)

    assert fix =~ "Start Docker"
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

    checks = run(environments: environments, route: true, port: 4321)

    assert %{status: :ok} = find(checks, "route:omashiki-agents")

    assert_received {:route, "agent:1", "omashiki-agents",
                     "http://host.docker.internal:4321/api/v1/health"}
  end

  test "a blocked route names the port and the host firewall" do
    FakeProbe.set(%{route: {:error, {:exit, 7}}})

    checks =
      run(
        environments: [environment("opencode", "restricted", "agent:1")],
        route: true,
        port: 4010
      )

    assert %{status: :error, summary: summary, fix: fix} = find(checks, "route:omashiki-agents")
    assert summary =~ "timeout without tools"
    assert fix =~ "port 4010"
    assert fix =~ "ufw"
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

  test "a readable host credential is ok" do
    credential = host_credential("opencode-local", "opencode")

    assert %{status: :ok} =
             find(run(host_credentials: [credential]), "host-credential:opencode-local")
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

  test "worst/1 ranks error over warn over ok" do
    assert Doctor.worst([]) == :ok
    assert Doctor.worst([%{status: :ok}, %{status: :warn}]) == :warn
    assert Doctor.worst([%{status: :warn}, %{status: :error}]) == :error
  end

  describe "Monitor" do
    test "runs the full doctor at boot, logs only problems, and keeps the route" do
      FakeProbe.set(%{route: {:error, {:exit, 7}}})
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
        [probe: FakeProbe, environments: [], host_credentials: [], identities: []],
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
