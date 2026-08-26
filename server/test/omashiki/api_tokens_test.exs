defmodule Omashiki.ApiTokensTest do
  use Omashiki.DataCase, async: false

  alias Omashiki.ApiTokens
  alias Omashiki.ApiTokens.{Hash, Token}

  test "creates an owner-bound token and stores only its hash" do
    user = user_fixture()
    assert {:ok, token, plaintext} = ApiTokens.create_for_user(user, %{name: "automation"})
    assert token.user_id == user.id
    assert token.token_hash == Hash.hmac(plaintext)
    refute Map.has_key?(Map.from_struct(token), :plaintext)
    assert {:ok, found} = ApiTokens.find_active_by_plaintext(plaintext)
    assert found.id == token.id
  end

  test "revocation is owner-scoped" do
    owner = user_fixture()
    other = user_fixture()
    {:ok, token, plaintext} = ApiTokens.create_for_user(owner, %{name: "automation"})

    assert {:error, :not_found} = ApiTokens.revoke(other, token.id)
    assert {:ok, _} = ApiTokens.revoke(owner, token.id)
    assert :error = ApiTokens.find_active_by_plaintext(plaintext)
  end

  describe "record_use/1" do
    setup do
      user = user_fixture()
      {:ok, token, _plaintext} = ApiTokens.create_for_user(user, %{name: "automation"})
      %{token: token}
    end

    test "writes last_used_at the first time the token is seen", %{token: token} do
      assert is_nil(token.last_used_at)
      assert :ok = ApiTokens.record_use(token)
      assert %DateTime{} = Repo.get!(Token, token.id).last_used_at
    end

    test "skips the write for a second use inside @use_resolution", %{token: token} do
      assert :ok = ApiTokens.record_use(token)
      first = Repo.get!(Token, token.id).last_used_at

      assert :ok = ApiTokens.record_use(token)
      assert Repo.get!(Token, token.id).last_used_at == first
    end

    test "writes again once the token falls outside @use_resolution", %{token: token} do
      stale = DateTime.add(DateTime.utc_now(:microsecond), -3600, :second)

      {1, _} =
        Token |> where([t], t.id == ^token.id) |> Repo.update_all(set: [last_used_at: stale])

      assert :ok = ApiTokens.record_use(token)
      assert DateTime.compare(Repo.get!(Token, token.id).last_used_at, stale) == :gt
    end

    test "is :ok for a token row that no longer exists", %{token: token} do
      Repo.delete!(token)
      assert :ok = ApiTokens.record_use(token)
    end

    test "the supervised async executor performs the same write", %{token: token} do
      # `config/test.exs` runs the write inline so it stays inside the sandbox
      # owner. Production runs it under `ApiTokens.TaskSupervisor`, so exercise
      # that branch at least once here — otherwise the executor the API actually
      # uses is never executed by the suite. The sandbox is in shared mode for
      # `async: false` cases, so the child can borrow the owner's connection;
      # the point of draining before the test ends is that a task outliving its
      # owner is exactly the "owner exited" defect this test guards against.
      previous = Application.get_env(:omashiki, :api_token_use_write)
      Application.put_env(:omashiki, :api_token_use_write, :async)
      on_exit(fn -> Application.put_env(:omashiki, :api_token_use_write, previous) end)

      assert :ok = ApiTokens.record_use(token)
      drain_use_writes()

      assert %DateTime{} = Repo.get!(Token, token.id).last_used_at
    end
  end

  defp drain_use_writes do
    Enum.reduce_while(1..500, :timeout, fn _, _ ->
      case Task.Supervisor.children(Omashiki.ApiTokens.TaskSupervisor) do
        [] -> {:halt, :ok}
        _ -> {:cont, Process.sleep(10)}
      end
    end)
    |> case do
      :ok -> :ok
      :timeout -> flunk("last_used_at writes did not drain")
    end
  end
end
