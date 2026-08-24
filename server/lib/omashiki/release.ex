defmodule Omashiki.Release do
  @moduledoc """
  Release tasks invoked from the production binary, where Mix is unavailable.

  Used by `bin/migrate` (the prod release entrypoint) to bring the database
  schema up to date before `bin/omashiki start` boots the supervision tree.
  """

  @app :omashiki

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
