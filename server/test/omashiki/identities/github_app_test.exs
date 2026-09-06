defmodule Omashiki.Identities.GithubAppTest do
  use ExUnit.Case, async: true

  alias Omashiki.Config.Identity
  alias Omashiki.Identities.GithubApp

  test "signs an RS256 App JWT the public key verifies, with iss = app_id" do
    {pem, public} = rsa_pair()

    identity = %Identity{
      name: "ana-bot",
      kind: "github-app",
      app_id: "123456",
      installation_id: "987654",
      private_key: pem
    }

    now = 1_700_000_000
    [header, payload, signature] = identity |> GithubApp.jwt(now) |> String.split(".")

    assert Jason.decode!(Base.url_decode64!(header, padding: false)) ==
             %{"alg" => "RS256", "typ" => "JWT"}

    assert %{"iss" => "123456", "iat" => iat, "exp" => exp} =
             Jason.decode!(Base.url_decode64!(payload, padding: false))

    assert iat == now - 60
    assert exp == now + 540

    assert :public_key.verify(
             header <> "." <> payload,
             :sha256,
             Base.url_decode64!(signature, padding: false),
             public
           )
  end

  test "a key that is not RSA PEM is refused before any network call" do
    identity = %Identity{
      name: "ana-bot",
      kind: "github-app",
      app_id: "1",
      installation_id: "2",
      private_key: "not a key"
    }

    assert_raise ArgumentError, ~r/not PEM/, fn -> GithubApp.jwt(identity) end
    assert {:error, {:private_key_invalid, _}} = GithubApp.installation_token(identity)
  end

  test "the struct never inspects its key" do
    {pem, _} = rsa_pair()

    identity = %Identity{
      name: "ana-bot",
      kind: "github-app",
      app_id: "1",
      installation_id: "2",
      private_key: pem
    }

    refute inspect(identity) =~ "PRIVATE KEY"
  end

  defp rsa_pair do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
    {pem, {:RSAPublicKey, elem(key, 2), elem(key, 3)}}
  end
end
