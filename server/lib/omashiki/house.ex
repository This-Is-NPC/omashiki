defmodule Omashiki.House do
  @moduledoc """
  This house's identity: the id its database was created with.

  Several houses can share one Docker daemon: two installs, a development
  house beside an image install, a test run beside either. A house labels the
  containers it runs with this id (`omashiki.house`) and only ever lists,
  reclaims or reports containers that carry it. Every offer to a remote
  worker carries it too, and the worker labels the attempt's container with
  it.
  """

  import Ecto.Query

  alias Omashiki.Repo

  @doc "The id, read from the database once and kept for the life of the node."
  @spec id() :: String.t()
  def id do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        id = Repo.one!(from(house in "house", select: type(house.id, Ecto.UUID)))
        :persistent_term.put(__MODULE__, id)
        id

      id ->
        id
    end
  end
end
