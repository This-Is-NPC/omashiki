defmodule Omashiki.Jobs.WebhookDeliveryWorker do
  @moduledoc "Oban dispatcher for one durable terminal webhook outbox row."

  use Oban.Worker,
    queue: :webhooks,
    max_attempts: 25,
    unique: [period: :infinity, keys: [:delivery_id], states: :incomplete]

  alias Omashiki.Jobs.Webhooks

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => delivery_id}}) do
    case Webhooks.deliver(delivery_id) do
      {:ok, status}
      when status in [:delivered, :dead, :pending, :delivering, "delivering", "delivered"] ->
        if status == :pending, do: {:snooze, 1}, else: :ok

      {:retry, next_attempt_at} ->
        seconds = max(DateTime.diff(next_attempt_at, DateTime.utc_now(:second), :second), 1)
        {:snooze, seconds}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
