defmodule Mix.Tasks.Omashiki.TokenTest do
  use Omashiki.DataCase, async: false

  alias Mix.Tasks.Omashiki.Token, as: TokenTask
  alias Omashiki.{Accounts, ApiTokens}
  alias Omashiki.ApiTokens.Token

  @secret_var "OMASHIKI_TEST_TOKEN_WEBHOOK_SECRET"

  setup do
    previous_shell = Mix.shell()
    previous_mode = Application.get_env(:omashiki, :auth_mode)
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
      Application.put_env(:omashiki, :auth_mode, previous_mode)
      System.delete_env(@secret_var)
    end)

    :ok
  end

  defp auth(mode), do: Application.put_env(:omashiki, :auth_mode, mode)

  defp output do
    Stream.repeatedly(fn ->
      receive do
        {:mix_shell, :info, [line]} -> line
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end

  defp create(args) do
    TokenTask.run(["create" | args])
    output()
  end

  describe "create" do
    test "issues a token for the local operator with auth disabled" do
      auth(:none)
      [created, _warning, plaintext] = create(~w(--name demo --env * --scopes read,submit))

      owner = Accounts.local_owner()
      assert created =~ "for #{owner.username}"
      assert {:ok, token} = ApiTokens.find_presented_by_plaintext(plaintext)
      assert token.user_id == owner.id
      assert token.scopes == ["read", "submit"]
      assert token.allowed_environments == ["*"]
      assert token.max_active_jobs == 10
    end

    test "issues for --user and requires it with auth enabled" do
      auth(:bearer)
      user = user_fixture(%{username: "alice"})

      assert_raise Mix.Error, ~r/pass --user/, fn ->
        TokenTask.run(~w(create --name demo --env app --scopes read))
      end

      [_created, _warning, plaintext] =
        create(
          ~w(--name ci --env app,web --scopes read,submit,cancel --max-active 3 --ttl-days 7 --user alice)
        )

      assert {:ok, token} = ApiTokens.find_presented_by_plaintext(plaintext)
      assert token.user_id == user.id
      assert token.allowed_environments == ["app", "web"]
      assert token.max_active_jobs == 3
    end

    test "reports ApiTokens validation errors" do
      auth(:none)

      assert_raise Mix.Error, ~r/scopes must be read, submit, and\/or cancel/, fn ->
        TokenTask.run(~w(create --name demo --env * --scopes admin))
      end

      assert_raise Mix.Error, ~r/expiry of 1 to/, fn ->
        TokenTask.run(~w(create --name demo --env * --scopes read --ttl-days 100000))
      end

      assert_raise Mix.Error, ~r/No user/, fn ->
        TokenTask.run(~w(create --name demo --env * --scopes read --user nobody))
      end
    end
  end

  test "lists and revokes the operator's tokens only" do
    auth(:bearer)
    alice = user_fixture(%{username: "alice"})
    bob = user_fixture(%{username: "bob"})
    {token, _} = api_token_fixture(alice, %{name: "alice-ci"})
    {other, _} = api_token_fixture(bob, %{name: "bob-ci"})

    TokenTask.run(~w(list --user alice))
    [line] = output()
    assert line =~ token.id
    assert line =~ "alice-ci"
    assert line =~ "webhook=none"

    assert_raise Mix.Error, ~r/No token/, fn ->
      TokenTask.run(["revoke", other.id, "--user", "alice"])
    end

    assert_raise Mix.Error, ~r/No token/, fn ->
      TokenTask.run(~w(revoke not-a-uuid --user alice))
    end

    TokenTask.run(["revoke", token.id, "--user", "alice"])
    assert ["Revoked token " <> _] = output()
    assert Token.status(Repo.get!(Token, token.id)) == :revoked
    assert is_nil(Repo.get!(Token, other.id).revoked_at)
  end

  describe "webhook" do
    setup do
      auth(:none)
      {token, _} = api_token_fixture(Accounts.local_owner())

      # The task reads the house policy from its file, so point it at one the
      # test owns rather than whatever this checkout declares.
      config =
        Path.join(System.tmp_dir!(), "omashiki-token-#{System.unique_integer([:positive])}")

      File.write!(config, "")
      previous = Application.get_env(:omashiki, :config_path)
      Application.put_env(:omashiki, :config_path, config)

      on_exit(fn ->
        Application.put_env(:omashiki, :config_path, previous)
        File.rm(config)
      end)

      {:ok, token: token, config: config}
    end

    test "sets the destination from an env var secret without printing it", %{token: token} do
      System.put_env(@secret_var, "very-secret-value")

      TokenTask.run([
        "webhook",
        token.id,
        "--url",
        "https://client.test/omashiki",
        "--secret-env",
        @secret_var
      ])

      lines = output()
      assert Enum.join(lines) =~ "https://client.test/omashiki"
      refute Enum.join(lines) =~ "very-secret-value"

      stored = Repo.get!(Token, token.id)
      assert stored.webhook_destination == "https://client.test/omashiki"
      assert is_binary(stored.webhook_secret_ciphertext)

      TokenTask.run(["list"])
      [line] = output()
      assert line =~ "webhook=https://client.test/omashiki"
      refute line =~ "very-secret-value"
    end

    test "refuses a missing secret variable and a private destination", %{token: token} do
      assert_raise Mix.Error, ~r/#{@secret_var} is not set/, fn ->
        TokenTask.run(
          ~w(webhook #{token.id} --url https://client.test/x --secret-env #{@secret_var})
        )
      end

      System.put_env(@secret_var, "very-secret-value")

      error =
        assert_raise Mix.Error, ~r/private_destination_not_allowed/, fn ->
          TokenTask.run(
            ~w(webhook #{token.id} --url http://127.0.0.1/x --secret-env #{@secret_var})
          )
        end

      refute error.message =~ "very-secret-value"
      assert is_nil(Repo.get!(Token, token.id).webhook_destination)
    end

    test "accepts a private destination when the house opts in", %{token: token, config: config} do
      File.write!(config, "[webhooks]\nallow_private_destinations = true\n")
      System.put_env(@secret_var, "very-secret-value")

      TokenTask.run(
        ~w(webhook #{token.id} --url http://127.0.0.1:8090/omashiki --secret-env #{@secret_var})
      )

      assert Repo.get!(Token, token.id).webhook_destination == "http://127.0.0.1:8090/omashiki"
    end

    test "clears the destination and keys", %{token: token} do
      {:ok, _} =
        ApiTokens.configure_webhook(token, %{
          destination: "https://client.test/omashiki",
          secret: "client-secret"
        })

      TokenTask.run(["webhook", token.id, "--clear"])
      assert ["Cleared the webhook" <> _] = output()

      stored = Repo.get!(Token, token.id)
      assert is_nil(stored.webhook_destination)
      assert is_nil(stored.webhook_secret_ciphertext)
      assert is_nil(stored.webhook_key_id)
    end

    test "needs either a url or --clear", %{token: token} do
      assert_raise Mix.Error, ~r/--clear/, fn -> TokenTask.run(["webhook", token.id]) end
    end
  end

  test "rejects unknown commands and options" do
    assert_raise Mix.Error, ~r/Usage/, fn -> TokenTask.run(["rotate"]) end
    assert_raise Mix.Error, ~r/Invalid option/, fn -> TokenTask.run(~w(list --secret s)) end
  end
end
