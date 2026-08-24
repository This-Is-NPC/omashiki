defmodule OmashikiWeb.OperationHelpers do
  @moduledoc false

  def age(nil), do: "—"

  def age(%DateTime{} = timestamp) do
    seconds = max(DateTime.diff(DateTime.utc_now(), timestamp, :second), 0)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3_600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  def age(_), do: "—"

  def timestamp(nil), do: "—"
  def timestamp(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")
  def timestamp(value), do: to_string(value)

  def status_class(status) do
    case to_string(status) do
      status when status in ["succeeded", "delivered"] -> "text-status-succeeded"
      status when status in ["failed", "dead"] -> "text-status-failed"
      status when status in ["running", "provisioning"] -> "text-status-running"
      status when status in ["cancelled"] -> "text-status-cancelled"
      _ -> "text-status-awaiting"
    end
  end

  def status_label(nil), do: "unknown"
  def status_label(status), do: status |> to_string() |> String.replace("_", " ")

  def payload_summary(payload) when is_map(payload) do
    %{
      keys: payload |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
      bytes: payload |> Jason.encode!() |> byte_size()
    }
  end

  def payload_summary(_), do: %{keys: [], bytes: 0}

  def json(value) do
    value
    |> Jason.encode!(pretty: true)
    |> String.slice(0, 8_000)
  rescue
    _ -> inspect(value)
  end

  def short_id(nil), do: "—"
  def short_id(value) when is_binary(value), do: String.slice(value, 0, 8)
  def short_id(value), do: to_string(value)

  def format_tokens(nil), do: "—"
  def format_tokens(value) when is_integer(value), do: Integer.to_string(value)
  def format_tokens(value), do: to_string(value)
end
