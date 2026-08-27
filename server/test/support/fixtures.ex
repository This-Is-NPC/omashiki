defmodule Omashiki.Fixtures do
  @moduledoc "Factories for authentication and queue-runtime tests."

  alias Omashiki.{Accounts, ApiTokens, Config}

  @config_key {__MODULE__, :config_map}

  def load_default_config! do
    put_config_map!(%{
      "credentials" => %{},
      "caches" => %{},
      "repositories" => %{},
      "environments" => %{},
      "limits" => %{}
    })
  end
  @plugins_source Path.expand("../../../plugins", __DIR__)

  def copy_plugins!(root) when is_binary(root) do
    dest = Path.join(root, "plugins")
    File.mkdir_p!(dest)

    for file <- Path.wildcard(Path.join(@plugins_source, "*.toml")) do
      File.cp!(file, Path.join(dest, Path.basename(file)))
    end

    :ok
  end

  def merge_config!(partial) when is_map(partial) do
    partial = stringify_keys(partial)

    merged =
      Enum.reduce(partial, config_map(), fn {section, value}, acc ->
        case {Map.get(acc, section), value} do
          {%{} = existing, %{} = new} -> Map.put(acc, section, Map.merge(existing, new))
          _ -> Map.put(acc, section, value)
        end
      end)

    put_config_map!(merged)
  end

  def user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Enum.into(attrs, %{
        email: "user#{n}@example.com",
        username: "user#{n}",
        password: "correct horse battery staple"
      })

    {:ok, user} =
      %Accounts.User{}
      |> Accounts.User.registration_changeset(attrs)
      |> Omashiki.Repo.insert()

    user
  end

  def api_token_fixture(%Accounts.User{} = user, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Enum.into(attrs, %{
        name: "Test token #{n}",
        expires_at: nil
      })

    {:ok, token, plaintext} = ApiTokens.create_for_user(user, attrs)
    {token, plaintext}
  end

  def credential_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])
    name = fetch(attrs, :name) || "test-cred-#{n}"

    entry = %{
      "provider" => fetch(attrs, :provider) || "anthropic",
      "model" => fetch(attrs, :model) || "claude-sonnet-4-5",
      "api_key" => fetch(attrs, :api_key) || "sk-test-#{n}"
    }

    entry = maybe_put(entry, "base_url", fetch(attrs, :base_url))
    merge_config!(%{"credentials" => %{name => entry}})
    Config.get_credential(name)
  end

  @doc """
  The `execution_capacity` row of a node, defaulting to the one this process
  runs as.

  Reads the node from `Config.current_machine/0` rather than naming it, so a test
  that switches node identity keeps asserting against the row that identity
  actually reserves from.
  """
  def capacity_row(node \\ nil) do
    Omashiki.Repo.get!(
      Omashiki.Jobs.ExecutionCapacity,
      node || Config.current_machine().name
    )
  end

  defp put_config_map!(map) do
    :persistent_term.put(@config_key, map)
    Config.load_map!(map)
  end

  defp config_map, do: :persistent_term.get(@config_key, %{})

  defp fetch(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify_keys(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp stringify_keys(value), do: value
end
