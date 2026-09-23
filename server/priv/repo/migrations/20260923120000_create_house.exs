defmodule Omashiki.Repo.Migrations.CreateHouse do
  use Ecto.Migration

  # One row: the id this house labels its containers with. It is created with
  # the database because the database is what decides which attempts are
  # live, so a house and the containers it may reclaim cannot disagree about
  # who owns them. The unique index on a constant keeps it to one row.
  def up do
    execute "CREATE TABLE house (id uuid PRIMARY KEY DEFAULT gen_random_uuid())"
    execute "CREATE UNIQUE INDEX house_single_row ON house ((true))"
    execute "INSERT INTO house DEFAULT VALUES"
  end
end
