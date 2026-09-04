defmodule Omashiki.Worker.Executor do
  @moduledoc """
  Runs a claimed execution offer to completion on a worker node.
  """

  alias Omashiki.Worker.{Complete, Offer}

  @callback run(Offer.t()) :: {:ok, Complete.t()} | {:error, term()}
end
