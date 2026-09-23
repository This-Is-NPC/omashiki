defmodule Omashiki.DeployStarterTest do
  @moduledoc """
  The starter configuration in deploy/ loads as the install guide ships it:
  alone in its directory, with the plugin manifests from the application.
  """

  use ExUnit.Case, async: false

  alias Omashiki.Config
  alias Omashiki.Config.Environment

  @starter Path.expand("../../../deploy/omashiki.toml", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "omashiki-starter-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "omashiki.toml")
    File.cp!(@starter, path)

    on_exit(fn ->
      Config.reset!()
      File.rm_rf!(dir)
    end)

    %{path: path}
  end

  test "loads one OpenCode environment that needs no repository", ctx do
    assert :ok = Config.load!(ctx.path)

    assert Config.repositories() == []

    assert %Environment{sink: "files", network: "restricted", preset: %{name: "opencode"}} =
             Config.get_environment("opencode")

    assert Config.get_host_credential("opencode-local")
  end
end
