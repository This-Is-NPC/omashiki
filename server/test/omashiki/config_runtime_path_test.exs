defmodule Omashiki.ConfigRuntimePathTest do
  use ExUnit.Case, async: false

  alias Omashiki.Config

  @runtime Path.expand("../../config/runtime.exs", __DIR__)
  @env ~w(OMASHIKI_CONFIG RELEASE_ROOT PORT OMASHIKI_DB_PORT)

  setup do
    saved = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  defp runtime_config do
    @runtime |> Elixir.Config.Reader.read!(env: :dev, target: :host) |> Keyword.fetch!(:omashiki)
  end

  defp write_toml!(body) do
    path =
      Path.join(System.tmp_dir!(), "omashiki-runtime-#{System.unique_integer([:positive])}.toml")

    File.write!(path, body)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "[app], [db] and [auth] come from the file OMASHIKI_CONFIG names" do
    path =
      write_toml!("""
      [app]
      host = "127.0.0.9"
      port = 4987

      [db]
      port = 5987

      [auth]
      enabled = false
      token_max_ttl_days = 7
      """)

    System.put_env("OMASHIKI_CONFIG", path)
    config = runtime_config()

    assert config[:config_path] == path
    assert config[OmashikiWeb.Endpoint][:http][:port] == 4987
    assert config[OmashikiWeb.Endpoint][:http][:ip] == {127, 0, 0, 9}
    assert config[Omashiki.Repo][:port] == 5987
    assert config[:auth_mode] == :none
    assert config[:token_max_ttl_days] == 7
  end

  test "a relative OMASHIKI_CONFIG is expanded against the working directory" do
    System.put_env("OMASHIKI_CONFIG", "omashiki.e2e.toml")

    assert runtime_config()[:config_path] == Path.expand("omashiki.e2e.toml")
  end

  test "a checkout without OMASHIKI_CONFIG reads omashiki.toml at the repository root" do
    System.put_env("OMASHIKI_CONFIG", "")

    config = runtime_config()

    assert config[:install] == :checkout
    assert config[:config_path] == Path.expand("../../../omashiki.toml", __DIR__)
  end

  test "a release without OMASHIKI_CONFIG names no file, so loading fails clearly" do
    System.put_env("RELEASE_ROOT", "/app")

    config = runtime_config()

    assert config[:install] == :release
    refute Keyword.has_key?(config, :config_path)

    previous = Application.fetch_env!(:omashiki, :config_path)
    Application.delete_env(:omashiki, :config_path)
    on_exit(fn -> Application.put_env(:omashiki, :config_path, previous) end)

    assert_raise Config.Error, ~r/OMASHIKI_CONFIG is not set/, &Config.default_path/0
  end
end
