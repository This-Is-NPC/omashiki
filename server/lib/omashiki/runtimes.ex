defmodule Omashiki.Runtimes do
  @moduledoc """
  Runtime value helpers for job environment snapshots.
  """

  alias Omashiki.Runtime.Spec

  def image(%Spec{backend: "docker", image: image})
      when is_binary(image) and image != "",
      do: image

  def image(_), do: nil

  def handler(%Spec{handler: handler}) when is_binary(handler), do: handler

  def handler(_), do: raise(ArgumentError, "runtime handler is required")
end
