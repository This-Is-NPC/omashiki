defmodule OmashikiWeb.AuthModeTest do
  use ExUnit.Case, async: true

  alias OmashikiWeb.AuthMode

  setup do
    previous = Application.get_env(:omashiki, :auth_mode)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:omashiki, :auth_mode)
      else
        Application.put_env(:omashiki, :auth_mode, previous)
      end
    end)

    :ok
  end

  test "mode defaults to :bearer" do
    Application.delete_env(:omashiki, :auth_mode)
    assert AuthMode.mode() == :bearer
  end

  test "mode accepts :none and \"none\"" do
    Application.put_env(:omashiki, :auth_mode, :none)
    assert AuthMode.mode() == :none

    Application.put_env(:omashiki, :auth_mode, "none")
    assert AuthMode.mode() == :none
  end

  test "unknown mode falls back to :bearer" do
    Application.put_env(:omashiki, :auth_mode, :open)
    assert AuthMode.mode() == :bearer
  end

  test "loopback_ip?/1 recognises v4 and v6 loopback" do
    assert AuthMode.loopback_ip?({127, 0, 0, 1})
    assert AuthMode.loopback_ip?({127, 1, 2, 3})
    assert AuthMode.loopback_ip?({0, 0, 0, 0, 0, 0, 0, 1})
    refute AuthMode.loopback_ip?({192, 168, 1, 10})
    refute AuthMode.loopback_ip?({0, 0, 0, 0})
    refute AuthMode.loopback_ip?({0, 0, 0, 0, 0, 0, 0, 0})
  end

  test "assert_boot_safe! warns but starts when :none with non-loopback bind" do
    Application.put_env(:omashiki, :auth_mode, :none)
    previous = Application.get_env(:omashiki, OmashikiWeb.Endpoint)

    Application.put_env(
      :omashiki,
      OmashikiWeb.Endpoint,
      Keyword.put(previous || [], :http, ip: {0, 0, 0, 0}, port: 4000)
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:omashiki, OmashikiWeb.Endpoint, previous)
      end
    end)

    # Disabling auth is the operator's call, so this no longer refuses to
    # start — but binding wide open without a credential has to be visible in
    # the log rather than silent.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert AuthMode.assert_boot_safe!() == :ok
      end)

    assert log =~ "auth is disabled"
    assert log =~ "without a credential"
  end

  test "assert_boot_safe! allows :none on loopback bind" do
    Application.put_env(:omashiki, :auth_mode, :none)
    previous = Application.get_env(:omashiki, OmashikiWeb.Endpoint)

    Application.put_env(
      :omashiki,
      OmashikiWeb.Endpoint,
      Keyword.put(previous || [], :http, ip: {127, 0, 0, 1}, port: 4000)
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:omashiki, OmashikiWeb.Endpoint, previous)
      end
    end)

    assert :ok = AuthMode.assert_boot_safe!()
  end
end
