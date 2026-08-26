defmodule Omashiki.SocketPathPartitionTest do
  # Mutates `MIX_TEST_PARTITION` and the socket path application env, both of
  # which are global. ExUnit runs sync modules only after every async module
  # has finished, so nothing else observes the mutation.
  use ExUnit.Case, async: false

  alias Omashiki.LlmEgress.Proxy
  alias Omashiki.SupplyChain.SocketBridge

  @cases [
    {Proxy, :llm_egress_socket_path, "llm-egress.sock"},
    {SocketBridge, :supply_chain_socket_path, "supply-chain.sock"}
  ]

  setup do
    partition = System.get_env("MIX_TEST_PARTITION")

    overrides =
      Map.new(@cases, fn {_mod, key, _name} ->
        {key, Application.fetch_env(:omashiki, key)}
      end)

    # Exercise the default branch, not whatever override the caller exported.
    Enum.each(@cases, fn {_mod, key, _name} -> Application.delete_env(:omashiki, key) end)

    on_exit(fn ->
      case partition do
        nil -> System.delete_env("MIX_TEST_PARTITION")
        value -> System.put_env("MIX_TEST_PARTITION", value)
      end

      Enum.each(overrides, fn
        {key, {:ok, value}} -> Application.put_env(:omashiki, key, value)
        {key, :error} -> Application.delete_env(:omashiki, key)
      end)
    end)

    :ok
  end

  defp user, do: System.get_env("USER", "user")

  test "an unset MIX_TEST_PARTITION yields exactly the pre-partition path" do
    System.delete_env("MIX_TEST_PARTITION")

    for {mod, _key, socket_name} <- @cases do
      # The literal shape shipped before partitioning, spelled out rather than
      # rebuilt from the implementation, so a regression cannot agree with it.
      expected = Path.join(System.tmp_dir!(), "omashiki-#{user()}-#{socket_name}")

      assert mod.path() == expected,
             "#{inspect(mod)} changed its non-test default path"
    end
  end

  test "an empty MIX_TEST_PARTITION is treated as unset" do
    System.put_env("MIX_TEST_PARTITION", "")

    for {mod, _key, socket_name} <- @cases do
      assert mod.path() == Path.join(System.tmp_dir!(), "omashiki-#{user()}-#{socket_name}")
    end
  end

  test "a set MIX_TEST_PARTITION is folded into the default path" do
    System.put_env("MIX_TEST_PARTITION", "7")

    for {mod, _key, socket_name} <- @cases do
      assert mod.path() == Path.join(System.tmp_dir!(), "omashiki-#{user()}-7-#{socket_name}")
    end
  end

  test "distinct partitions never share a socket path" do
    for {mod, _key, _name} <- @cases do
      System.put_env("MIX_TEST_PARTITION", "1")
      first = mod.path()

      System.put_env("MIX_TEST_PARTITION", "2")
      second = mod.path()

      System.delete_env("MIX_TEST_PARTITION")
      unpartitioned = mod.path()

      assert first != second,
             "#{inspect(mod)} collides across partitions, which fails boot with :address_in_use"

      assert first != unpartitioned
      assert second != unpartitioned
    end
  end

  test "an explicit configured path still wins over the partition default" do
    System.put_env("MIX_TEST_PARTITION", "7")

    for {mod, key, _name} <- @cases do
      configured = Path.join(System.tmp_dir!(), "omashiki-explicit-#{key}.sock")
      Application.put_env(:omashiki, key, configured)

      assert mod.path() == configured
    end
  end
end
