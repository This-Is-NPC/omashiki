defmodule Mix.Tasks.Omashiki.Token do
  @moduledoc """
  Issues, lists, and revokes API tokens, and sets their terminal webhook.

      mix omashiki.token create --name NAME --env ENV[,ENV] --scopes read,submit[,cancel]
                                [--max-active N] [--ttl-days N] [--user USERNAME]
      mix omashiki.token list [--user USERNAME]
      mix omashiki.token revoke ID [--user USERNAME]
      mix omashiki.token webhook ID --url URL --secret-env VAR [--user USERNAME]
      mix omashiki.token webhook ID --clear [--user USERNAME]

  With authentication disabled the task acts as the local operator.
  Otherwise `--user` (username or email) is required.

  `create` prints the plaintext token once. `webhook` reads the signing
  secret from the named environment variable, so it never appears in argv
  or shell history, and never prints it.
  """

  use Mix.Task

  alias Omashiki.{Accounts, ApiTokens}
  alias Omashiki.ApiTokens.{Audit, Token}

  @shortdoc "Issue, list, and revoke API tokens and set their webhook."

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

  @impl Mix.Task
  def run(args) do
    {opts, positional} = parse!(args)
    start_repo()
    command(positional, opts)
  end

  # Only the repo. The whole application would bring up a second set of
  # listeners and queue consumers next to the house that is already running.
  defp start_repo do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started([:postgrex, :ecto_sql])

    case Omashiki.Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
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
        Mix.shell().info("Created token #{token.id} for #{user.username}.")
        Mix.shell().info("Copy it now; it is not shown again:")
        Mix.shell().info(plaintext)

      {:error, reason} ->
        Mix.raise("Token not created: #{ApiTokens.format_error(reason)}")
    end
  end

  defp command(["list"], opts) do
    case ApiTokens.list_for_user(user!(opts)) do
      [] -> Mix.shell().info("No tokens.")
      tokens -> Enum.each(tokens, &Mix.shell().info(describe(&1)))
    end
  end

  defp command(["revoke", id], opts) do
    case ApiTokens.revoke(user!(opts), id) do
      {:ok, token} -> Mix.shell().info("Revoked token #{token.id}.")
      {:error, :not_found} -> Mix.raise("No token #{id} for this operator.")
      {:error, reason} -> Mix.raise("Token not revoked: #{ApiTokens.format_error(reason)}")
    end
  end

  defp command(["webhook", id], opts) do
    token = token!(user!(opts), id)

    case {Keyword.get(opts, :clear, false), Keyword.get(opts, :url)} do
      {true, nil} ->
        {:ok, _} = ApiTokens.clear_webhook(token)
        Mix.shell().info("Cleared the webhook of token #{token.id}.")

      {false, url} when is_binary(url) ->
        secret = secret!(Keyword.get(opts, :secret_env))

        case ApiTokens.configure_webhook(token, %{destination: url, secret: secret}) do
          {:ok, configured} ->
            Mix.shell().info(
              "Token #{configured.id} now notifies #{configured.webhook_destination}."
            )

          {:error, reason} ->
            Mix.raise("Webhook not set: #{ApiTokens.format_error(reason)}")
        end

      _ ->
        Mix.raise("webhook needs either --url URL --secret-env VAR or --clear")
    end
  end

  defp command(_positional, _opts), do: Mix.raise(usage())

  defp parse!(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, positional, []} ->
        {opts, positional}

      {_opts, _positional, invalid} ->
        Mix.raise("Invalid option #{inspect(invalid)}\n" <> usage())
    end
  end

  defp user!(opts) do
    case Keyword.get(opts, :user) do
      nil ->
        if OmashikiWeb.AuthMode.disabled?(),
          do: Accounts.local_owner() || Mix.raise("No local operator could be resolved."),
          else: Mix.raise("Authentication is enabled; pass --user USERNAME.")

      identifier ->
        Accounts.get_user_by_identifier(identifier) ||
          Mix.raise("No user with identifier #{inspect(identifier)}.")
    end
  end

  defp token!(user, id) do
    ApiTokens.get_for_user(user, id) || Mix.raise("No token #{id} for this operator.")
  end

  defp secret!(nil), do: Mix.raise("--secret-env names the variable that holds the secret")

  defp secret!(var) do
    case System.get_env(var) do
      secret when is_binary(secret) and secret != "" -> secret
      _ -> Mix.raise("Environment variable #{var} is not set.")
    end
  end

  defp required!(opts, key) do
    Keyword.get(opts, key) ||
      Mix.raise("create needs --#{key |> to_string() |> String.replace("_", "-")}")
  end

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
    Usage:
      mix omashiki.token create --name NAME --env ENV[,ENV] --scopes read,submit[,cancel] [--max-active N] [--ttl-days N] [--user USERNAME]
      mix omashiki.token list [--user USERNAME]
      mix omashiki.token revoke ID [--user USERNAME]
      mix omashiki.token webhook ID --url URL --secret-env VAR [--user USERNAME]
      mix omashiki.token webhook ID --clear [--user USERNAME]
    """
  end
end
