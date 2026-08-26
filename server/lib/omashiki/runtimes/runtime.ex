defmodule Omashiki.Runtimes.Runtime do
  @moduledoc """
  Where an agent harness runs (Docker image today).

  Declared in a job environment snapshot. Docker `image` and runtime delivery
  settings live in `config` for `kind == "docker"`.
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          key: String.t() | nil,
          kind: String.t() | nil,
          config: map(),
          status: String.t()
        }

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}

  @kinds ~w(docker)
  @statuses ~w(active retired)

  embedded_schema do
    field :key, :string
    field :kind, :string
    field :config, :map, default: %{}
    field :status, :string, default: "active"
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  def changeset(runtime, attrs) do
    runtime
    |> cast(attrs, [:key, :kind, :config, :status])
    |> validate_required([:key, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_docker_image()
  end

  defp validate_docker_image(changeset) do
    kind = get_field(changeset, :kind)
    config = get_field(changeset, :config) || %{}

    image = config_get(config, "image") || config_get(config, :image)

    cond do
      kind == "docker" and (not is_binary(image) or image == "") ->
        add_error(changeset, :config, "docker runtime requires config.image")

      true ->
        changeset
    end
  end

  defp config_get(map, key) when is_map(map), do: Map.get(map, key)
  defp config_get(_, _), do: nil
end
