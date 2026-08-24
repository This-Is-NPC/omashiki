defmodule Omashiki.AccountsLocalOwnerTest do
  @moduledoc """
  `local_owner/0` is what stands in for a logged-in user when
  `auth.enabled = false` in omashiki.toml. It has to work on a database with
  no users at all — a fresh clone with auth turned off — because every screen
  assumes `current_user` and would crash on nil.
  """
  use Omashiki.DataCase, async: false

  alias Omashiki.Accounts

  test "creates a local owner when the database has no users" do
    assert Accounts.count() == 0

    user = Accounts.local_owner()

    assert user.username == "local"
    assert Accounts.count() == 1
  end

  test "is idempotent — a second call returns the same user" do
    first = Accounts.local_owner()
    second = Accounts.local_owner()

    assert first.id == second.id
    assert Accounts.count() == 1
  end

  test "returns the existing operator instead of creating another" do
    {:ok, existing} =
      Accounts.register_user(%{
        username: "howl",
        email: "howl@omashiki.local",
        password: "correct horse battery staple"
      })

    assert Accounts.local_owner().id == existing.id
    assert Accounts.count() == 1
  end

  test "the generated owner has no usable password" do
    user = Accounts.local_owner()

    assert Accounts.authenticate(user.username, "") == {:error, :invalid_credentials}
    assert Accounts.authenticate(user.username, "local") == {:error, :invalid_credentials}
  end
end
