defmodule Omashiki.Security.NetworkTest do
  use ExUnit.Case, async: true

  alias Omashiki.Security.Network

  test "rejects private, loopback, link-local, reserved, and mapped addresses" do
    private = [
      {10, 0, 0, 1},
      {127, 0, 0, 1},
      {169, 254, 169, 254},
      {192, 168, 1, 1},
      {172, 16, 0, 1},
      {100, 64, 0, 1},
      {192, 0, 2, 1},
      {224, 0, 0, 1},
      {0, 0, 0, 0},
      {0, 0, 0, 0, 0, 0, 0, 1},
      {0, 0, 0, 0, 0, 0, 0, 0},
      {0xFD00, 0, 0, 0, 0, 0, 0, 1},
      {0xFE80, 0, 0, 0, 0, 0, 0, 1},
      {0xFF02, 0, 0, 0, 0, 0, 0, 1},
      {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1},
      {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}
    ]

    assert Enum.all?(private, &(not Network.public_address?(&1)))
    assert Network.public_address?({93, 184, 216, 34})
    assert Network.public_address?({0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888})
  end

  test "rejects any private address returned by DNS" do
    resolver = fn "service.example.test" -> {:ok, [{93, 184, 216, 34}, {10, 0, 0, 7}]} end

    assert {:error, :restricted_destination} =
             Network.authorize_host("service.example.test", resolver: resolver)

    assert :ok =
             Network.authorize_host("service.example.test",
               resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end
             )
  end

  test "fails closed for unresolved hosts" do
    assert {:error, :unresolved_destination} =
             Network.authorize_host("missing.example.test",
               resolver: fn _ -> {:error, :nxdomain} end
             )
  end

  test "fails closed for malformed resolver answers" do
    assert {:error, :restricted_destination} =
             Network.authorize_host("malformed.example.test",
               resolver: fn _ -> {:ok, [{:bad}]} end
             )
  end
end
