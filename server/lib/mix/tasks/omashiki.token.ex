defmodule Mix.Tasks.Omashiki.Token do
  @moduledoc """
  Issues, lists, and revokes API tokens and sets their webhook.

      mix omashiki.token create --name NAME --env ENV[,ENV] --scopes read,submit[,cancel][,review]
                                [--max-active N] [--ttl-days N] [--user USERNAME]
      mix omashiki.token list [--user USERNAME]
      mix omashiki.token revoke ID [--user USERNAME]
      mix omashiki.token webhook ID --url URL --secret-env VAR [--user USERNAME]
      mix omashiki.token webhook ID --clear [--user USERNAME]

  See `Omashiki.Cli.Token`, which the release runs as `bin/token`.
  """

  use Mix.Task

  @shortdoc "Issue, list, and revoke API tokens and set their webhook."

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    Omashiki.Cli.run(Omashiki.Cli.Token, args)
  end
end
