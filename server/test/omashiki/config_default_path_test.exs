defmodule Omashiki.ConfigDefaultPathTest do
  use ExUnit.Case, async: false

  alias Omashiki.Config

  setup do
    on_exit(fn -> System.delete_env("OMASHIKI_CONFIG") end)
    :ok
  end

  defp legacy_default_path do
    config_dir = Path.join([File.cwd!(), "lib", "omashiki"])
    Path.expand("../../../omashiki.toml", config_dir)
  end

  test "default_path returns repo-root omashiki.toml when OMASHIKI_CONFIG is unset" do
    System.delete_env("OMASHIKI_CONFIG")

    assert Config.default_path() == legacy_default_path()
  end

  test "default_path returns repo-root omashiki.toml when OMASHIKI_CONFIG is blank" do
    System.put_env("OMASHIKI_CONFIG", "")

    assert Config.default_path() == legacy_default_path()
  end

  test "default_path expands OMASHIKI_CONFIG when set" do
    custom = Path.join(System.tmp_dir!(), "omashiki-custom-#{System.unique_integer()}.toml")
    System.put_env("OMASHIKI_CONFIG", custom)

    assert Config.default_path() == Path.expand(custom)
  end

  test "default_path expands relative OMASHIKI_CONFIG against cwd" do
    System.put_env("OMASHIKI_CONFIG", "omashiki.e2e.toml")

    assert Config.default_path() == Path.expand("omashiki.e2e.toml")
  end
end
