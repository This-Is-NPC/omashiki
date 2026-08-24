defmodule Omashiki.Jobs.Contract.Payload.V2 do
  @moduledoc "Neutral public harness payload."

  @version 2
  @keys ["instruction", "context"]
  @control_keys ~w(harness provider auth model)
  @max_bytes 1_048_576

  def version, do: @version

  def validate(payload) when is_map(payload) do
    errors =
      []
      |> validate_keys(payload)
      |> validate_instruction(payload)
      |> validate_context(payload)

    if errors == [], do: {:ok, payload}, else: {:error, Enum.reverse(errors)}
  end

  def validate(_), do: {:error, [%{field: "payload", code: "object_required"}]}

  defp validate_keys(errors, payload) do
    Enum.reduce(Map.keys(payload), errors, fn key, acc ->
      cond do
        key in @keys ->
          acc

        key in @control_keys ->
          [%{field: "payload.#{key}", code: "control_field_not_allowed"} | acc]

        true ->
          [%{field: "payload.#{key}", code: "unknown_field"} | acc]
      end
    end)
  end

  defp validate_instruction(errors, payload) do
    case Map.fetch(payload, "instruction") do
      {:ok, value} when is_binary(value) ->
        cond do
          not String.valid?(value) ->
            [%{field: "payload.instruction", code: "utf8_required"} | errors]

          byte_size(value) > @max_bytes ->
            [%{field: "payload.instruction", code: "too_large"} | errors]

          byte_size(value) == 0 or String.trim(value) == "" ->
            [%{field: "payload.instruction", code: "blank"} | errors]

          true ->
            errors
        end

      {:ok, _} ->
        [%{field: "payload.instruction", code: "string_required"} | errors]

      :error ->
        [%{field: "payload.instruction", code: "required"} | errors]
    end
  end

  defp validate_context(errors, payload) do
    case Map.fetch(payload, "context") do
      :error ->
        errors

      {:ok, context} when is_map(context) ->
        cond do
          not json_value?(context) ->
            [%{field: "payload.context", code: "invalid_json_value"} | errors]

          encoded_size(context) > @max_bytes ->
            [%{field: "payload.context", code: "too_large"} | errors]

          true ->
            errors
        end

      {:ok, _} ->
        [%{field: "payload.context", code: "object_required"} | errors]
    end
  end

  defp json_value?(nil), do: true
  defp json_value?(value) when is_binary(value), do: String.valid?(value)
  defp json_value?(value) when is_boolean(value) or is_integer(value), do: true
  defp json_value?(value) when is_float(value), do: value == value
  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)

  defp json_value?(value) when is_map(value),
    do: Enum.all?(value, fn {key, value} -> is_binary(key) and json_value?(value) end)

  defp json_value?(_), do: false

  defp encoded_size(value), do: value |> Jason.encode!() |> byte_size()
end
