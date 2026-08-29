defmodule Omashiki.Plugin.OptionSchema do
  @moduledoc false

  alias Omashiki.Harness.CliJson
  alias Omashiki.Plugin.Manifest

  @option_spec_keys ~w(type default optional prefix allowed exact_set)
  @types ~w(positive_int absolute_path model boolean string string_list enum)

  def validate_schema!(%Manifest{options: options}, where) when is_map(options) do
    Enum.each(options, fn {name, spec} ->
      spec_where = "#{where}.options.#{name}"
      spec = stringify(spec)

      unknown = Map.keys(spec) -- @option_spec_keys

      if unknown != [],
        do: raise(ArgumentError, "#{spec_where}: unknown field #{inspect(hd(unknown))}")

      type = Map.fetch!(spec, "type")

      if type not in @types,
        do: raise(ArgumentError, "#{spec_where}.type invalid: #{inspect(type)}")

      case type do
        "enum" ->
          allowed = Map.get(spec, "allowed")

          if not is_list(allowed) or allowed == [] do
            raise ArgumentError, "#{spec_where}.allowed required for enum"
          end

        _ ->
          :ok
      end
    end)
  end

  def validate(%Manifest{options: schema}, options) when is_map(options) do
    merged = merged_options(schema, options)
    unknown = Map.keys(options) -- Map.keys(schema)

    cond do
      unknown != [] ->
        {:error, {:unknown_options, Enum.sort(unknown)}}

      true ->
        Enum.reduce_while(schema, :ok, fn {name, spec}, :ok ->
          value = Map.get(merged, name)

          case validate_value(name, spec, value) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  def validate(_, _), do: {:error, :options_must_be_a_map}

  defp merged_options(schema, raw) do
    defaults =
      schema
      |> Enum.map(fn {k, spec} -> {k, Map.get(spec, "default")} end)
      |> Map.new()

    Map.merge(defaults, raw)
  end

  defp validate_value("timeout_ms", %{"type" => "positive_int"}, value) do
    if CliJson.positive_timeout?(value), do: :ok, else: {:error, :invalid_timeout}
  end

  defp validate_value(_name, %{"type" => "positive_int", "optional" => true}, nil), do: :ok

  defp validate_value(_name, %{"type" => "positive_int"}, value) do
    if positive_int?(value), do: :ok, else: {:error, :invalid_timeout}
  end

  defp validate_value(_name, %{"type" => "absolute_path"} = spec, value) do
    prefix = Map.get(spec, "prefix")

    cond do
      not CliJson.valid_absolute_path?(value) ->
        {:error, path_error(spec)}

      is_binary(prefix) and not CliJson.valid_path?(value, prefix) ->
        {:error, path_error(spec)}

      true ->
        :ok
    end
  end

  defp validate_value(_name, %{"type" => "model", "optional" => true}, nil), do: :ok

  defp validate_value(_name, %{"type" => "model"}, value) do
    if CliJson.valid_model?(value), do: :ok, else: {:error, :invalid_model}
  end

  defp validate_value(_name, %{"type" => "boolean"}, value) do
    if is_boolean(value), do: :ok, else: {:error, :invalid_web_search}
  end

  defp validate_value(_name, %{"type" => "string", "optional" => true}, nil), do: :ok

  defp validate_value(_name, %{"type" => "string"}, value) do
    if is_binary(value) and value != "", do: :ok, else: {:error, :invalid_string}
  end

  defp validate_value(_name, %{"type" => "string_list", "exact_set" => true} = spec, value) do
    allowed = Map.get(spec, "default")

    if is_list(value) and is_list(allowed) and Enum.sort(value) == Enum.sort(allowed) and
         length(value) == length(Enum.uniq(value)) do
      :ok
    else
      {:error, :invalid_allowed_tools}
    end
  end

  defp validate_value(_name, %{"type" => "string_list"}, value) do
    if is_list(value) and Enum.all?(value, &is_binary/1),
      do: :ok,
      else: {:error, :invalid_string_list}
  end

  defp validate_value(_name, %{"type" => "enum", "optional" => true}, nil), do: :ok

  defp validate_value(_name, %{"type" => "enum", "allowed" => allowed}, value) do
    if value in allowed, do: :ok, else: {:error, :invalid_reasoning_effort}
  end

  defp validate_value(name, spec, value) do
    {:error, {:invalid_option, name, spec, value}}
  end

  defp positive_int?(value), do: is_integer(value) and value > 0

  defp path_error(%{"prefix" => "/tmp"}), do: :invalid_invocation_path
  defp path_error(%{"prefix" => "/run/omashiki/state"}), do: :invalid_credentials_path
  defp path_error(_), do: :invalid_path

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
