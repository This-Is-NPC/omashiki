defmodule Omashiki.Config.HostCredential do
  @moduledoc """
  Declared operator credential that lives outside the configuration root.

  Only host origin paths are declared; contents are copied into a private
  per-attempt directory at attempt start and are never held by the registry.
  The struct derives a redacting `Inspect` so origins stay out of logs.
  """

  alias Omashiki.Config.Error

  @derive {Inspect, except: [:files]}
  @enforce_keys [:name, :kind, :files]
  defstruct @enforce_keys

  @container_dir "/run/omashiki/state"
  @name ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  # kind => [{declared field, container file name, required?}]
  @kinds %{
    "opencode" => [{"auth", "auth.json", true}, {"config", "opencode.json", false}],
    "claude-code" => [{"credentials", "claude-credentials.json", true}],
    "codex" => [{"credentials", "codex-auth.json", true}]
  }

  @doc "Container directory the per-attempt credential directory is mounted at."
  def container_dir, do: @container_dir

  @doc "Supported harness credential layouts."
  def kinds, do: @kinds |> Map.keys() |> Enum.sort()

  @doc """
  Build the declared `[host_credentials]` section.

  Origins are kept in their declared form. `~/` is **not** expanded here: the
  home that matters is the one on the machine that runs the container, which
  in a manager/worker split is not the machine loading this file.
  `Omashiki.Runtime.HostCredentials.materialize/3` expands it at copy time.
  Absolute paths pass through; `./` and `../` are rejected because they would
  silently bind the credential to whichever working directory the process
  happened to start in. Nothing is checked for existence: a missing or
  mid-rotation credential must fail one attempt, not the boot.
  """
  def build!(section) when is_map(section) do
    section
    |> Enum.map(fn {name, attrs} -> build_one!(name, attrs) end)
    |> Enum.sort_by(& &1.name)
  end

  def build!(_), do: raise(Error, "[host_credentials] must be a table")

  defp build_one!(name, attrs) do
    where = "host_credentials.#{name}"

    unless is_binary(name) and Regex.match?(@name, name) do
      raise Error, "#{where} name must be kebab-case"
    end

    attrs = require_table!(attrs, where)
    kind = require_string!(attrs, "kind", where)

    fields =
      Map.get(@kinds, kind) ||
        raise(Error, "#{where}.kind must be one of #{Enum.join(kinds(), ", ")}")

    reject_unknown!(attrs, ["kind" | Enum.map(fields, &elem(&1, 0))], where)

    files =
      Enum.reduce(fields, %{}, fn {field, file, required?}, acc ->
        case Map.get(attrs, field) do
          nil when required? -> raise Error, "#{where}: missing required field #{inspect(field)}"
          nil -> acc
          value -> Map.put(acc, file, origin!(value, where, field))
        end
      end)

    %__MODULE__{name: name, kind: kind, files: files}
  end

  defp origin!(value, where, field) do
    unless is_binary(value) and value != "" and String.valid?(value) and
             not String.contains?(value, <<0>>) do
      raise Error, "#{where}.#{field} must be a non-empty path"
    end

    case value do
      "~/" <> rest when rest != "" ->
        value

      _ ->
        unless Path.type(value) == :absolute do
          raise Error,
                "#{where}.#{field} must be an absolute host path or start with ~/ " <>
                  "(relative paths are not allowed)"
        end

        Path.expand(value)
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
