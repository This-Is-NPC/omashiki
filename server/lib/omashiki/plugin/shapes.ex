defmodule Omashiki.Plugin.Shapes do
  @moduledoc false
  alias Omashiki.Harness.{CliJson, Result}

  def decode_exec_output(output, prefix, decode_stdout), do: CliJson.decode_exec_output(output, prefix, decode_stdout)

  def normalize(%{"shape" => "object"} = output, decoded) when is_map(decoded) do
    text = get_path(decoded, Map.get(output, "text", "text"))

    if is_binary(text) do
      usage = get_path(decoded, "usage") || %{}
      um = Map.get(output, "usage", %{})

      {:ok,
       %Result{
         assistant_text: text,
         input_tokens: int(get_usage(usage, um, "input")),
         output_tokens: int(get_usage(usage, um, "output")),
         cached_input_tokens: int(get_usage(usage, um, "cached_input")),
         cache_write_tokens: int(get_usage(usage, um, "cache_write")),
         model_resolved: str(get_path(decoded, Map.get(output, "model", "model"))),
         provider: str(get_path(decoded, Map.get(output, "provider", "provider"))),
         raw: decoded
       }}
    else
      {:error, {:unexpected_json, CliJson.summarize(decoded)}}
    end
  end

  def normalize(%{"shape" => "jsonl_agent_end"} = output, events) when is_list(events) do
    type = Map.get(output, "event_type", "agent_end")

    case Enum.find(events, &(&1["type"] == type)) do
      %{"messages" => msgs} when is_list(msgs) ->
        assistants = Enum.filter(msgs, &(&1["role"] == "assistant"))
        usage = Enum.reduce(assistants, %{}, &sum_usage/2)
        last = List.last(assistants)

        {:ok,
         %Result{
           assistant_text: assistant_text(last),
           input_tokens: Map.get(usage, :input),
           output_tokens: Map.get(usage, :output),
           cached_input_tokens: Map.get(usage, :cache_read),
           cache_write_tokens: Map.get(usage, :cache_write),
           model_resolved: str(last && last["model"]),
           provider: str(last && last["provider"]),
           raw: %{"events" => events}
         }}

      _ ->
        {:error, {:unexpected_json, inspect(events)}}
    end
  end

  def normalize(%{"shape" => "result_envelope"} = output, decoded) when is_map(decoded) do
    um = Map.get(output, "usage", %{})

    case decoded do
      %{"type" => "result", "is_error" => false} = d ->
        mu = Map.get(d, "modelUsage", %{})
        usage = Map.get(d, "usage") || first_model_usage(mu) || %{}

        {:ok,
         %Result{
           assistant_text: Map.get(d, "result", ""),
           input_tokens: int(get_usage(usage, um, "input") || usage["input_tokens"] || usage["inputTokens"]),
           output_tokens: int(get_usage(usage, um, "output") || usage["output_tokens"] || usage["outputTokens"]),
           cached_input_tokens: int(get_usage(usage, um, "cached_input") || usage["cached_input_tokens"] || usage["cacheReadInputTokens"]),
           cache_write_tokens:
             int(get_usage(usage, um, "cache_write") || usage["cache_creation_input_tokens"] || usage["cacheWriteInputTokens"] || usage["cache_write_input_tokens"]),
           model_resolved: str(Map.get(d, "model") || first_model(mu)),
           provider: str(Map.get(output, "provider_default")),
           raw: decoded
         }}

      %{"type" => "result", "is_error" => true} = d ->
        {:error, {:result_error, CliJson.summarize(Map.get(d, "result", d))}}

      _ ->
        {:error, {:unexpected_json, CliJson.summarize(decoded)}}
    end
  end

  def normalize(%{"shape" => shape}, decoded), do: {:error, {:unknown_shape, shape, CliJson.summarize(decoded)}}

  defp get_path(map, path) when is_map(map) and is_binary(path) do
    Enum.reduce(String.split(path, "."), map, fn key, current ->
      if is_map(current), do: Map.get(current, key)
    end)
  end

  defp get_path(_, _), do: nil

  defp get_usage(usage, usage_map, key) when is_map(usage) and is_map(usage_map) do
    case Map.get(usage_map, key) do
      nil -> nil
      path -> get_path(usage, path)
    end
  end

  defp sum_usage(%{"usage" => usage}, acc) when is_map(usage) do
    acc
    |> add(:input, usage["input"])
    |> add(:output, usage["output"])
    |> add(:cache_read, usage["cacheRead"])
    |> add(:cache_write, usage["cacheWrite"])
  end

  defp sum_usage(_, acc), do: acc

  defp add(acc, key, value) when is_integer(value) and value >= 0, do: Map.update(acc, key, value, &(&1 + value))
  defp add(acc, _, _), do: acc

  defp assistant_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == "text"))
    |> Enum.map_join("", & &1["text"])
  end

  defp assistant_text(_), do: ""

  defp first_model(model_usage) when is_map(model_usage) do
    model_usage |> Map.keys() |> Enum.sort() |> List.first()
  end

  defp first_model(_), do: nil

  defp first_model_usage(model_usage) when is_map(model_usage) do
    case first_model(model_usage) do
      nil -> nil
      model -> Map.get(model_usage, model)
    end
  end

  defp first_model_usage(_), do: nil

  defp int(value), do: CliJson.integer_or_nil(value)
  defp str(value), do: CliJson.string_or_nil(value)
end
