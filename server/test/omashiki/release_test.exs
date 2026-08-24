defmodule Omashiki.ReleaseTest do
  use ExUnit.Case, async: true

  # Note: actually invoking Omashiki.Release.migrate/0 against the test repo
  # conflicts with Ecto.Adapters.SQL.Sandbox (Ecto.Migrator.with_repo starts
  # its own connection, which is not in the sandbox's allow list). The
  # migrate path is exercised end-to-end when the prod image boots
  # (CMD ["bin/migrate"]) and gated by the release workflow. This unit
  # spec only verifies the module surface so a rename / accidental removal
  # is caught fast.

  test "module exports migrate/0" do
    Code.ensure_loaded!(Omashiki.Release)
    assert function_exported?(Omashiki.Release, :migrate, 0)
  end

  test "migrate/0 reads ecto_repos from application env" do
    # Sanity check that the release task's data source matches the production
    # config — if someone removes :ecto_repos, the prod entrypoint silently
    # becomes a no-op.
    assert [Omashiki.Repo] == Application.fetch_env!(:omashiki, :ecto_repos)
  end
end
