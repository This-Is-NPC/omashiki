defmodule Omashiki.ConfigRuntimeSecretTest do
  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)
  @env ~w(SECRET_KEY_BASE OMASHIKI_ROLE DATABASE_URL OMASHIKI_CONFIG RELEASE_ROOT)

  setup do
    saved = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    System.put_env("DATABASE_URL", "ecto://postgres:postgres@localhost/omashiki")
    System.put_env("OMASHIKI_CONFIG", Path.join(System.tmp_dir!(), "omashiki-absent.toml"))
    :ok
  end

  defp prod_endpoint_config do
    @runtime
    |> Config.Reader.read!(env: :prod, target: :host)
    |> get_in([:omashiki, OmashikiWeb.Endpoint])
  end

  for role <- ~w(embedded manager worker) do
    test "the #{role} role refuses a SECRET_KEY_BASE shorter than 64 characters" do
      System.put_env("OMASHIKI_ROLE", unquote(role))
      System.put_env("SECRET_KEY_BASE", String.duplicate("a", 63))

      assert_raise RuntimeError,
                   "SECRET_KEY_BASE must be at least 64 characters; " <>
                     "generate one with `openssl rand -base64 48`",
                   &prod_endpoint_config/0
    end

    test "the #{role} role signs with a 64-character SECRET_KEY_BASE" do
      System.put_env("OMASHIKI_ROLE", unquote(role))
      secret = String.duplicate("a", 64)
      System.put_env("SECRET_KEY_BASE", secret)

      assert prod_endpoint_config()[:secret_key_base] == secret
    end
  end
end
