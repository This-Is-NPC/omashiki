defmodule Omashiki.CredentialsTest do
  use Omashiki.DataCase, async: false

  alias Omashiki.Credentials

  test "list_credentials/0 returns Config credentials" do
    cred = credential_fixture(%{name: "listed"})
    names = Enum.map(Credentials.list_credentials(), & &1.name)
    assert "listed" in names
    assert cred.provider
  end

  test "get_credential!/1 looks up by name" do
    _ = credential_fixture(%{name: "by_name", model: "gpt-test"})
    assert Credentials.get_credential!("by_name").model == "gpt-test"
  end

  test "masked_key/1 redacts the secret" do
    cred = credential_fixture(%{api_key: "sk-secret-abcdef"})
    masked = Credentials.masked_key(cred)
    assert masked =~ "****"
    refute masked =~ "sk-secret"
  end
end
