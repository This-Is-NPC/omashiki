defmodule Omashiki.Cli.Token do
  @moduledoc """
  Issues, lists, and revokes API tokens, and sets their terminal webhook.

      create --name NAME --env ENV[,ENV] --scopes read,submit[,cancel][,review]
             [--max-active N] [--ttl-days N] [--user USERNAME]
      list [--user USERNAME]
      revoke ID [--user USERNAME]
      webhook ID --url URL --secret-env VAR [--user USERNAME]
      webhook ID --clear [--user USERNAME]

  Run it as `mix omashiki.token` in a checkout and as `bin/token` in the
  release.

  With authentication disabled the tool acts as the local operator.
  Otherwise `--user` (username or email) is required.

  `create` prints the plaintext token once. `webhook` reads the signing
  secret from the named environment variable, so it never appears in argv
  or shell history, and never prints it. The destination follows the
  `[webhooks]` policy of `omashiki.toml`.
  """

  @behaviour Omashiki.Cli

  alias Omashiki.{Accounts, ApiTokens}
  alias Omashiki.ApiTokens.{Audit, Token}

  @default_max_active 10
  @default_ttl_days 30

  @switches [
    name: :string,
    env: :string,
    scopes: :string,
    max_active: :integer,
    ttl_days: :integer,
    user: :string,
    url: :string,
    secret_env: :string,
    clear: :boolean
  ]

  # Only the repo. The whole application would bring up a second set of
  # listeners and queue consumers next to the house that is already running.
  @impl Omashiki.Cli
  def start do
    {:ok, _} = Application.ensure_all_started([:postgrex, :ecto_sql])

    case Omashiki.Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @impl Omashiki.Cli
  def run(argv) do
    {opts, positional} = parse!(argv)
    {0, output(command(positional, opts))}
  catch
    {:failed, message} -> {1, output([message])}
  end

  defp command(["create"], opts) do
    user = user!(opts)

    attrs = %{
      name: required!(opts, :name),
      allowed_environments: list(required!(opts, :env)),
      scopes: list(required!(opts, :scopes)),
      max_active_jobs: Keyword.get(opts, :max_active, @default_max_active),
      ttl_days: Keyword.get(opts, :ttl_days, @default_ttl_days)
    }

    case ApiTokens.create_for_user(user, attrs) do
      {:ok, token, plaintext} ->
        Audit.record(token, "issue")

        [
          "Created token #{token.id} for #{user.username}.",
          "Copy it now; it is not shown again:",
          plaintext
        ]

      {:error, reason} ->
        fail!("Token not created: #{ApiTokens.format_error(reason)}")
    end
  end

  defp command(["list"], opts) do
    case ApiTokens.list_for_user(user!(opts)) do
      [] -> ["No tokens."]
      tokens -> Enum.map(tokens, &describe/1)
    end
  end

  defp command(["revoke", id], opts) do
    case ApiTokens.revoke(user!(opts), id) do
      {:ok, token} -> ["Revoked token #{token.id}."]
      {:error, :not_found} -> fail!("No token #{id} for this operator.")
      {:error, reason} -> fail!("Token not revoked: #{ApiTokens.format_error(reason)}")
    end
  end

  defp command(["webhook", id], opts) do
    token = token!(user!(opts), id)

    case {Keyword.get(opts, :clear, false), Keyword.get(opts, :url)} do
      {true, nil} ->
        {:ok, _} = ApiTokens.clear_webhook(token)
        ["Cleared the webhook of token #{token.id}."]

      {false, url} when is_binary(url) ->
        secret = secret!(Keyword.get(opts, :secret_env))
        Omashiki.Config.load_webhooks!()

        case ApiTokens.configure_webhook(token, %{destination: url, secret: secret}) do
          {:ok, configured} ->
            ["Token #{configured.id} now notifies #{configured.webhook_destination}."]

          {:error, reason} ->
            fail!("Webhook not set: #{ApiTokens.format_error(reason)}")
        end

      _ ->
        fail!("webhook needs either --url URL --secret-env VAR or --clear")
    end
  end

  defp command(_positional, _opts), do: fail!(usage())

  defp parse!(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, positional, []} -> {opts, positional}
      {_opts, _positional, invalid} -> fail!("Invalid option #{inspect(invalid)}\n" <> usage())
    end
  end

  defp user!(opts) do
    case Keyword.get(opts, :user) do
      nil ->
        if OmashikiWeb.AuthMode.disabled?(),
          do: Accounts.local_owner() || fail!("No local operator could be resolved."),
          else: fail!("Authentication is enabled; pass --user USERNAME.")

      identifier ->
        Accounts.get_user_by_identifier(identifier) ||
          fail!("No user with identifier #{inspect(identifier)}.")
    end
  end

  defp token!(user, id) do
    ApiTokens.get_for_user(user, id) || fail!("No token #{id} for this operator.")
  end

  defp secret!(nil), do: fail!("--secret-env names the variable that holds the secret")

  defp secret!(var) do
    case System.get_env(var) do
      secret when is_binary(secret) and secret != "" -> secret
      _ -> fail!("Environment variable #{var} is not set.")
    end
  end

  defp required!(opts, key) do
    Keyword.get(opts, key) ||
      fail!("create needs --#{key |> to_string() |> String.replace("_", "-")}")
  end

  defp fail!(message), do: throw({:failed, message})

  defp output(lines), do: Enum.map(lines, &[&1, ?\n]) |> IO.iodata_to_binary()

  defp list(value), do: value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp describe(%Token{} = token) do
    Enum.join(
      [
        token.id,
        token.name,
        Token.status(token),
        "scopes=" <> Enum.join(token.scopes, ","),
        "env=" <> Enum.join(token.allowed_environments, ","),
        "max_active=#{token.max_active_jobs}",
        "expires=" <> DateTime.to_iso8601(token.expires_at),
        "webhook=" <> (token.webhook_destination || "none")
      ],
      "  "
    )
  end

  defp usage do
    """
    Usage (mix omashiki.token in a checkout, bin/token in the release):
      create --name NAME --env ENV[,ENV] --scopes read,submit[,cancel][,review] [--max-active N] [--ttl-days N] [--user USERNAME]
      list [--user USERNAME]
      revoke ID [--user USERNAME]
      webhook ID --url URL --secret-env VAR [--user USERNAME]
      webhook ID --clear [--user USERNAME]\
    """
  end
end
