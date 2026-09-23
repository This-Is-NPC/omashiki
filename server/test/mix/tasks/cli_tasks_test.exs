defmodule Mix.Tasks.Omashiki.CliTasksTest do
  use Omashiki.DataCase, async: false

  import ExUnit.CaptureIO

  setup do
    previous_mode = Application.get_env(:omashiki, :auth_mode)
    previous_path = Application.get_env(:omashiki, :config_path)
    Application.put_env(:omashiki, :auth_mode, :none)

    on_exit(fn ->
      Application.put_env(:omashiki, :auth_mode, previous_mode)
      Application.put_env(:omashiki, :config_path, previous_path)
    end)
  end

  test "omashiki.token runs Omashiki.Cli.Token" do
    assert capture_io(fn -> Mix.Tasks.Omashiki.Token.run(["list"]) end) == "No tokens.\n"
  end

  test "omashiki.doctor runs Omashiki.Cli.Doctor" do
    Application.put_env(:omashiki, :config_path, "/nonexistent/omashiki.toml")

    output =
      capture_io(fn ->
        assert {:shutdown, 1} = catch_exit(Mix.Tasks.Omashiki.Doctor.run([]))
      end)

    assert output =~ "error  config  omashiki.toml not found at /nonexistent/omashiki.toml"
  end
end
