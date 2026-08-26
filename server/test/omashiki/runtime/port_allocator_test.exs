defmodule Omashiki.Runtime.PortAllocatorTest do
  use ExUnit.Case, async: false

  alias Omashiki.Runtime.PortAllocator

  test "leases unique ports atomically and returns a scope's existing lease" do
    scopes = Enum.map(1..16, &"allocator-test-#{&1}-#{System.unique_integer([:positive])}")
    on_exit(fn -> Enum.each(scopes, &PortAllocator.release/1) end)

    leases =
      scopes
      |> Task.async_stream(fn scope -> {scope, PortAllocator.reserve(scope)} end,
        max_concurrency: 16,
        ordered: false
      )
      |> Map.new(fn {:ok, {scope, {:ok, port}}} -> {scope, port} end)

    ports = Map.values(leases)

    assert length(Enum.uniq(ports)) == length(scopes)
    first = hd(scopes)
    assert {:ok, leases[first]} == PortAllocator.reserve(first)
  end
end
