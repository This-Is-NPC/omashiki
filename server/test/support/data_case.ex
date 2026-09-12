defmodule Omashiki.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Omashiki.DataCase, async: true`, although
  this option is not recommended for other databases.

  Note: `Omashiki.Config` lives in `:persistent_term`. DataCase
  resets and reloads a minimal snapshot per test; prefer
  `async: false` for tests that mutate Config via fixtures.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Omashiki.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Omashiki.DataCase
      import Omashiki.Fixtures
    end
  end

  setup tags do
    Omashiki.DataCase.setup_sandbox(tags)
    Omashiki.DataCase.setup_config()
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Omashiki.Repo,
        shared: not tags[:async],
        ownership_timeout: tags[:ownership_timeout] || 120_000
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  Reset Config and load the minimal test environment snapshot.
  Shared by DataCase and ConnCase.
  """
  def setup_config do
    Omashiki.Config.reset!()
    Omashiki.Fixtures.load_default_config!()
    on_exit(fn -> Omashiki.Config.reset!() end)
    :ok
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
