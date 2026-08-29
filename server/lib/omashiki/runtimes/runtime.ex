defmodule Omashiki.Runtime.Spec do
  @moduledoc "Immutable runtime selected for one resolved environment."

  @enforce_keys [:name, :backend, :handler, :distribution, :plugin, :image]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          backend: String.t(),
          handler: String.t(),
          distribution: String.t(),
          plugin: String.t(),
          image: String.t()
        }
end
