defmodule Omashiki.AccountsTest do
  use Omashiki.DataCase, async: false

  alias Omashiki.Accounts

  describe "argon2 cost (test profile)" do
    @tag :performance
    test "registration completes well under 50 ms" do
      {micros, {:ok, _user}} =
        :timer.tc(fn ->
          Accounts.register_user(%{
            email: "perf@example.com",
            username: "perfuser",
            password: "perf-password"
          })
        end)

      ms = micros / 1_000

      # Test profile uses t_cost: 1, m_cost: 8 (config/test.exs). The plan's
      # success metric is < 50 ms — keep us honest if someone bumps the cost
      # without realising what it does to suite runtime.
      assert ms < 50,
             "argon2 registration took #{Float.round(ms, 2)} ms — bump argon2_elixir cost or revisit"
    end
  end

  describe "register_user/1" do
    test "creates the first user with a hashed password" do
      assert {:ok, user} =
               Accounts.register_user(%{
                 email: "first@example.com",
                 username: "first",
                 password: "first-password"
               })

      assert user.id
      assert String.starts_with?(user.password_hash, "$argon2id$")
      assert is_nil(user.password), "virtual :password must be cleared after hashing"
    end

    test "refuses a second registration" do
      {:ok, _} =
        Accounts.register_user(%{
          email: "first@example.com",
          username: "first",
          password: "first-password"
        })

      assert {:error, :registration_closed} =
               Accounts.register_user(%{
                 email: "second@example.com",
                 username: "second",
                 password: "second-password"
               })
    end

    test "validates required fields" do
      assert {:error, %Ecto.Changeset{} = changeset} = Accounts.register_user(%{})
      assert %{email: _, username: _, password: _} = errors_on(changeset)
    end

    test "rejects short passwords" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Accounts.register_user(%{
                 email: "x@example.com",
                 username: "xx",
                 password: "abc"
               })

      assert "Must be at least 8 characters." in errors_on(changeset).password
    end
  end

  describe "authenticate/2" do
    setup do
      {:ok, user} =
        Accounts.register_user(%{
          email: "auth@example.com",
          username: "auth",
          password: "right-password"
        })

      %{user: user}
    end

    test "returns {:ok, user} on a correct email + password", %{user: user} do
      assert {:ok, %{id: id}} = Accounts.authenticate("auth@example.com", "right-password")
      assert id == user.id
    end

    test "returns {:ok, user} on a correct username + password", %{user: user} do
      assert {:ok, %{id: id}} = Accounts.authenticate("auth", "right-password")
      assert id == user.id
    end

    test "returns :invalid_credentials on a wrong password" do
      assert {:error, :invalid_credentials} =
               Accounts.authenticate("auth", "wrong")
    end

    test "returns :invalid_credentials on an unknown identifier (and runs no_user_verify)" do
      assert {:error, :invalid_credentials} =
               Accounts.authenticate("nobody@example.com", "anything")
    end
  end

  describe "update_password/2" do
    test "rotates the hash" do
      {:ok, user} =
        Accounts.register_user(%{
          email: "u@example.com",
          username: "uu",
          password: "old-password"
        })

      old_hash = user.password_hash
      assert {:ok, updated} = Accounts.update_password(user, "new-password-1")
      refute updated.password_hash == old_hash
      assert {:ok, _} = Accounts.authenticate("uu", "new-password-1")
      assert {:error, :invalid_credentials} = Accounts.authenticate("uu", "old-password")
    end
  end

  describe "concurrent registration" do
    test "exactly one of two concurrent signups succeeds" do
      parent = self()

      tasks =
        for n <- 1..5 do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Omashiki.Repo, parent, self())

            Accounts.register_user(%{
              email: "race#{n}@example.com",
              username: "race#{n}",
              password: "race-password-#{n}"
            })
          end)
        end

      results = Task.await_many(tasks, 5_000)

      successes = Enum.count(results, &match?({:ok, _}, &1))
      closed = Enum.count(results, &match?({:error, :registration_closed}, &1))

      assert successes == 1, "expected exactly 1 successful signup, got #{successes}"
      assert successes + closed == length(results)
      assert Accounts.count() == 1
    end
  end

  describe "signup_open?/0" do
    test "true with no users" do
      assert Accounts.signup_open?()
    end

    test "false once a user exists" do
      {:ok, _} =
        Accounts.register_user(%{
          email: "u@example.com",
          username: "uu",
          password: "password-1"
        })

      refute Accounts.signup_open?()
    end
  end
end
