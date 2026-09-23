defmodule Mix.Tasks.Omashiki.Doctor do
  @moduledoc """
  Diagnoses the installation against `omashiki.toml`.

      mix omashiki.doctor

  See `Omashiki.Cli.Doctor`, which the release runs as `bin/doctor`.
  """

  use Mix.Task

  @shortdoc "Diagnose Docker, images, agent network, credentials, and identities."

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    Omashiki.Cli.run(Omashiki.Cli.Doctor, args)
  end
end
