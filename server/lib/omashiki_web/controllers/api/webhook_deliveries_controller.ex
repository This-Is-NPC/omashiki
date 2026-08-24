defmodule OmashikiWeb.Api.WebhookDeliveriesController do
  use OmashikiWeb, :controller

  alias Omashiki.Jobs.Webhooks

  action_fallback OmashikiWeb.FallbackController

  def index(conn, %{"id" => job_id}) do
    actor = conn.assigns[:current_token] || conn.assigns[:current_user]

    with {:ok, deliveries} <- Webhooks.list_for_job(job_id, actor) do
      json(conn, %{data: deliveries})
    end
  end
end
