defmodule Omashiki.Runtimes do
  @moduledoc """
  Runtime value helpers for job environment snapshots.
  """

  alias Omashiki.Runtime.Spec

  @repository "https://github.com/This-Is-NPC/omashiki.git"

  def image(%Spec{backend: "docker", image: image})
      when is_binary(image) and image != "",
      do: image

  def image(_), do: nil

  @doc """
  How an operator provides `image` when it is not on the machine, with the
  build command of `install` (`:checkout` or `:release`), which defaults to
  the `:install` the runtime configuration resolved.
  """
  def provide_image(image, install \\ Application.fetch_env!(:omashiki, :install))

  def provide_image(image, :checkout) when is_binary(image),
    do:
      "Omashiki never pulls images. Build #{image} (`mise run images` builds the agent " <>
        "images), or pull it deliberately with `docker pull #{image}`."

  def provide_image(image, :release) when is_binary(image),
    do:
      "Omashiki never pulls images. Build #{image} from agent/ in the Omashiki repository " <>
        "at this release (for the OpenCode image: `docker build -t #{image} " <>
        "\"#{@repository}#v#{Application.spec(:omashiki, :vsn)}:agent\"`), or pull it " <>
        "deliberately with `docker pull #{image}`."

  def handler(%Spec{handler: handler}) when is_binary(handler), do: handler

  def handler(_), do: raise(ArgumentError, "runtime handler is required")
end
