defmodule Mix.Tasks.Omashiki.Users.ResetPasswordTest do
  use Omashiki.DataCase, async: false

  alias Mix.Tasks.Omashiki.Users.ResetPassword
  alias Omashiki.Accounts

  describe "reset_password/3" do
    setup do
      user =
        user_fixture(%{
          email: "alice@example.com",
          username: "alice",
          password: "old-password"
        })

      %{user: user}
    end

    test "rotates the hash and lets the user log in with the new password",
         %{user: user} do
      old_hash = user.password_hash

      assert {:ok, updated} =
               ResetPassword.reset_password("alice", "new-password-1", "new-password-1")

      refute updated.password_hash == old_hash
      assert {:ok, _} = Accounts.authenticate("alice", "new-password-1")
      assert {:error, :invalid_credentials} = Accounts.authenticate("alice", "old-password")
    end

    test "matches by email, not just username" do
      assert {:ok, _} =
               ResetPassword.reset_password(
                 "alice@example.com",
                 "fresh-password",
                 "fresh-password"
               )
    end

    test "fails with :passwords_do_not_match" do
      assert {:error, :passwords_do_not_match} =
               ResetPassword.reset_password("alice", "x", "y")
    end

    test "fails with :no_such_user when identifier is unknown" do
      assert {:error, :no_such_user} =
               ResetPassword.reset_password("nobody", "p", "p")
    end

    test "propagates length validation as a changeset" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               ResetPassword.reset_password("alice", "abc", "abc")

      assert "Must be at least 8 characters." in errors_on(changeset).password
    end
  end
end
