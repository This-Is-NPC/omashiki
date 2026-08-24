defmodule Omashiki.Jobs.ExecutionCapacity do
  @moduledoc "The database row that serializes the global local-container budget."

  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}

  schema "execution_capacity" do
    field :capacity, :integer
    field :active, :integer
    timestamps(type: :utc_datetime_usec)
  end
end
