defmodule Omashiki.ApiTokensTest do
  use Omashiki.DataCase, async: false

  alias Omashiki.ApiTokens
  alias Omashiki.ApiTokens.Hash

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
end
