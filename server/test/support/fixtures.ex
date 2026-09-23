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

  def copy_plugins!(root) when is_binary(root) do
    dest = Path.join(root, "plugins")
    File.mkdir_p!(dest)

    for file <- Path.wildcard(Path.join(Omashiki.Plugin.Loader.shipped_dir(), "*.toml")) do
      File.cp!(file, Path.join(dest, Path.basename(file)))
    end

    :ok
  end

  @doc """
  A complete `omashiki.toml` for a root prepared with `copy_plugins!/1` and a
  Git repository at `repo`. `credentials: false` leaves `[credentials]` for a
  piece; `credential_toml/1` writes it.
  """
  def house_toml(opts \\ []) do
    credentials =
      if Keyword.get(opts, :credentials, true),
        do: credential_toml(Keyword.get(opts, :model, "some-model")),
        else: ""

    """
    [limits]
    max_concurrent_containers = #{Keyword.get(opts, :containers, 4)}

    [repositories.app]
    path = "repo"
    base_branch = "main"

    [runtimes.docker.runc.debian.images]
    opencode = "omashiki/agent:latest"

    [presets.opencode]
    plugin = "opencode"

    [environments.opencode]
    runtime = "docker.runc.debian"
    sink = "git"
    packages = []
    preset = "opencode"
    executables = ["git"]
    credentials = ["provider"]
    caches = []
    timeout_ms = 1800000
    network = "restricted"
    mounts = []
    pre_steps = []
    post_steps = []

    [environments.opencode.policy]
    mode = "off"

    [environments.opencode.resources]
    cpus = 2.0
    memory = "2GB"
    pids = 256
    """ <> credentials
  end

  @doc "Root ignores file permissions, so read-only directory tests cannot run as root."
  def root_user?, do: System.cmd("id", ["-u"]) |> elem(0) |> String.trim() == "0"

  def credential_toml(model) do
    """

    [credentials.provider]
    provider = "openai_compat"
    model = "#{model}"
    api_key = "plaintext-key"
    """
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

  @doc """
  A secret-scan policy with a fixed key, so fingerprints repeat within a
  test run, allowing the fingerprints in `allowed`.
  """
  def scan_policy(allowed \\ []),
    do: %Omashiki.Jobs.SecretScan.Policy{key: String.duplicate("k", 32), allowed: allowed}

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
        scopes: ["read", "submit", "cancel"],
        allowed_environments: ["*"],
        max_active_jobs: 100,
        ttl_days: 30
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
