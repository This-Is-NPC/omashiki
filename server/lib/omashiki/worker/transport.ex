defmodule Omashiki.Worker.Transport do
  @moduledoc """
  Worker execution transport seam.

  Phase 0 ships an in-process `Omashiki.Worker.Local` implementation.
  Remote workers will implement the same callbacks over HTTP in a later phase.
  """

  alias Omashiki.Worker.{Complete, Execution, Offer}

  @type execution :: Execution.t()

  @callback offer(Offer.t()) :: {:ok, Offer.t()} | {:error, term()}
  @callback accept(Offer.t()) :: {:ok, execution()} | {:error, term()}
  @callback heartbeat(execution()) :: :ok | :cancel | {:error, term()}
  @callback complete(execution(), Complete.t()) :: :ok | {:error, term()}
  @callback execute(Offer.t(), keyword()) :: {:ok, Complete.t()} | {:error, term()}
end
