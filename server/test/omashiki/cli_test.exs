defmodule Omashiki.CliTest do
  use Omashiki.DataCase, async: false

  import ExUnit.CaptureIO

  alias Omashiki.Cli

  setup do
    previous_mode = Application.get_env(:omashiki, :auth_mode)
    Application.put_env(:omashiki, :auth_mode, :none)
    on_exit(fn -> Application.put_env(:omashiki, :auth_mode, previous_mode) end)
  end

  test "starts the tool and prints its output" do
    assert capture_io(fn -> assert :ok = Cli.run(Cli.Token, ["list"]) end) == "No tokens.\n"
  end

  test "prints the output of a failed run and exits with its status" do
    output =
      capture_io(fn ->
        assert {:shutdown, 1} = catch_exit(Cli.run(Cli.Token, ["rotate"]))
      end)

    assert output =~ "Usage"
  end
end
