defmodule Omashiki.Runtimes do
  @moduledoc """
  Runtime value helpers for job environment snapshots.
  """

  alias Omashiki.Runtime.Spec

  def image(%Spec{backend: "docker", image: image})
      when is_binary(image) and image != "",
      do: image

  def image(_), do: nil

  @doc "How an operator provides `image` when it is not on the machine."
  def provide_image(image) when is_binary(image),
    do:
      "Omashiki never pulls images. Build #{image} (`mise run images` builds the agent " <>
        "images), or pull it deliberately with `docker pull #{image}`."

  def handler(%Spec{handler: handler}) when is_binary(handler), do: handler

  def handler(_), do: raise(ArgumentError, "runtime handler is required")
end
