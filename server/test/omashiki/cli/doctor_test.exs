defmodule Omashiki.Cli.DoctorTest do
  use ExUnit.Case, async: false

  alias Omashiki.Cli.Doctor, as: DoctorCli
  alias Omashiki.Config
  alias Omashiki.Doctor.FakeProbe

  import Omashiki.Fixtures

  setup do
    dir =
      Path.join(System.tmp_dir!(), "omashiki-cli-doctor-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    copy_plugins!(dir)
    path = Path.join(dir, "omashiki.toml")
    previous = Application.get_env(:omashiki, :config_path)
    Application.put_env(:omashiki, :config_path, path)
    Application.put_env(:omashiki, :doctor_probe, FakeProbe)

    on_exit(fn ->
      Config.reset!()
      FakeProbe.reset()
      Application.delete_env(:omashiki, :doctor_probe)
      Application.put_env(:omashiki, :config_path, previous)
      File.rm_rf!(dir)
    end)

    %{path: path}
  end

  defp write(path) do
    File.write!(path, """
    [limits]
    max_concurrent_containers = 1

    [runtimes.docker.runc.debian.images]
    opencode = "omashiki/agent:latest"

    [presets.opencode]
    plugin = "opencode"

    [environments.chat]
    runtime = "docker.runc.debian"
    sink = "none"
    packages = []
    preset = "opencode"
    executables = []
    credentials = []
    timeout_ms = 600000
    network = "none"
    mounts = []

    [environments.chat.policy]
    mode = "off"

    [environments.chat.resources]
    cpus = 1.0
    memory = "1GB"
    pids = 256
    """)
  end

  test "prints one line per check and exits zero when nothing is an error", %{path: path} do
    write(path)

    assert {0, output} = DoctorCli.run([])
    lines = String.split(output, "\n", trim: true)

    assert "ok     docker  Docker answers." in lines
    assert Enum.all?(lines, &String.starts_with?(&1, "ok "))
  end

  test "exits non-zero and prints the fix when a check is an error", %{path: path} do
    write(path)
    FakeProbe.set(%{runtime: {:error, :econnrefused}})

    assert {1, output} = DoctorCli.run([])
    assert [problem, fix | others] = String.split(output, "\n", trim: true)
    assert problem =~ ~r/^error  docker  Docker does not answer/
    assert fix =~ ~r/^       fix: Start Docker/
    assert Enum.all?(others, &String.starts_with?(&1, "ok "))
  end

  test "reports a configuration it cannot load as the config check", %{path: path} do
    assert {1, output} = DoctorCli.run([])

    assert output ==
             "error  config  omashiki.toml not found at #{path}\n" <>
               "       fix: Correct omashiki.toml, then run the doctor again.\n"
  end
end
