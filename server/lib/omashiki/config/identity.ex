defmodule Omashiki.Config.Identity do
  @moduledoc """
  Who the agent *is* when it acts outside the sandbox.

  Declared as `[identities.<name>]` in the house registry and attached to a
  preset by name (`presets.<p>.identities = ["ana-bot"]`). An identity is a
  face the house wears on the agent's behalf; it is not a kind of work, not a
  field on the job, and never a table the worker receives.

  The first kind is `github-app`: `app_id`, `installation_id`, and a
  `private_key` that must be an `${env:VAR}` reference resolved at load, like
  every other secret in this file. The resolved key lives only in this struct
  inside the live snapshot; the preset, the admitted environment, the offer
  and the sandbox carry `public/1` — name, kind, and the public ids.
  """

  alias Omashiki.Config.Error

  @derive {Inspect, except: [:private_key]}
  @enforce_keys [:name, :kind, :app_id, :installation_id, :private_key]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          kind: String.t(),
          app_id: String.t(),
          installation_id: String.t(),
          private_key: String.t()
        }

  @type public :: %{
          name: String.t(),
          kind: String.t(),
          app_id: String.t(),
          installation_id: String.t()
        }

  @name ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  @env_reference ~r/^\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}$/
  @kinds %{"github-app" => ~w(app_id installation_id private_key)}

  @doc "Supported identity kinds."
  def kinds, do: @kinds |> Map.keys() |> Enum.sort()

  @doc "Build the declared `[identities]` section, sorted by name."
  def build!(section) when is_map(section) do
    section
    |> Enum.map(fn {name, attrs} -> build_one!(name, attrs) end)
    |> Enum.sort_by(& &1.name)
  end

  def build!(_), do: raise(Error, "[identities] must be a table")

  @doc "The part of an identity that may leave the house: never the key."
  @spec public(t() | map()) :: public()
  def public(%__MODULE__{} = identity) do
    %{
      name: identity.name,
      kind: identity.kind,
      app_id: identity.app_id,
      installation_id: identity.installation_id
    }
  end

  def public(%{} = map) do
    %{
      name: fetch(map, :name),
      kind: fetch(map, :kind),
      app_id: fetch(map, :app_id),
      installation_id: fetch(map, :installation_id)
    }
  end

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp build_one!(name, attrs) do
    where = "identities.#{name}"

    unless is_binary(name) and Regex.match?(@name, name) do
      raise Error, "#{where} name must be kebab-case"
    end

    attrs = require_table!(attrs, where)
    kind = require_string!(attrs, "kind", where)

    fields =
      Map.get(@kinds, kind) ||
        raise(Error, "#{where}.kind must be one of #{Enum.join(kinds(), ", ")}")

    reject_unknown!(attrs, ["kind" | fields], where)

    %__MODULE__{
      name: name,
      kind: kind,
      app_id: require_id!(attrs, "app_id", where),
      installation_id: require_id!(attrs, "installation_id", where),
      private_key: require_env_secret!(attrs, "private_key", where)
    }
  end

  # GitHub ids are numeric but travel as strings in every API; accept both
  # spellings in TOML and store the string.
  defp require_id!(attrs, key, where) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> value
      value when is_integer(value) and value > 0 -> Integer.to_string(value)
      nil -> raise Error, "#{where}: missing required field #{inspect(key)}"
      _ -> raise Error, "#{where}.#{key} must be a non-empty string"
    end
  end

  # A private key is only ever `${env:VAR}`. Plaintext in a tracked file is
  # refused outright rather than accepted with a warning.
  defp require_env_secret!(attrs, key, where) do
    case Map.get(attrs, key) do
      nil ->
        raise Error, "#{where}: missing required field #{inspect(key)}"

      value when is_binary(value) ->
        case Regex.run(@env_reference, value) do
          [_, var] ->
            case System.get_env(var) do
              resolved when is_binary(resolved) and resolved != "" ->
                resolved

              _ ->
                raise Error,
                      "#{where}.#{key} references environment variable #{var}, which is unset or empty"
            end

          nil ->
            raise Error, "#{where}.#{key} must be an ${env:VAR} reference, never a literal key"
        end

      _ ->
        raise Error, "#{where}.#{key} must be an ${env:VAR} reference"
    end
  end

  defp require_table!(attrs, _where) when is_map(attrs),
    do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  defp require_table!(_, where), do: raise(Error, "#{where} must be a table")

  defp require_string!(attrs, key, where) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> value
      _ -> raise Error, "#{where}: missing required field #{inspect(key)}"
    end
  end

  defp reject_unknown!(attrs, allowed, where) do
    case Map.keys(attrs) -- allowed do
      [] -> :ok
      unknown -> raise Error, "#{where}: unknown fields #{inspect(Enum.sort(unknown))}"
    end
  end
end
