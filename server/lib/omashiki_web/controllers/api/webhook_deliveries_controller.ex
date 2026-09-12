defmodule OmashikiWeb.Api.WebhookDeliveriesController do
  use OmashikiWeb.Api.Controller

  alias Omashiki.Jobs.Webhooks
  alias OmashikiWeb.Api.Conn, as: ApiConn
  alias OmashikiWeb.ApiSpec.Schemas

  tags(["webhooks"])

  operation(:index,
    summary: "List webhook deliveries for a job",
    security: [%{"bearer" => ["read"]}],
    parameters: [
      id: [in: :path, type: :string, required: true]
    ],
    responses: %{
      200 => {"Deliveries", "application/json", Schemas.WebhookDeliveryListResponse}
    }
  )

  def index(conn, params) do
    job_id = Map.get(params, :id) || Map.get(params, "id")
    actor = ApiConn.actor(conn)

    with {:ok, deliveries} <- Webhooks.list_for_job(job_id, actor) do
      json(conn, %{data: deliveries})
    end
  end

  operation(:redeliver,
    summary: "Requeue a failed or dead webhook delivery",
    security: [%{"bearer" => ["submit"]}],
    parameters: [
      id: [in: :path, type: :string, required: true],
      delivery_id: [in: :path, type: :string, required: true]
    ],
    responses: %{
      202 => {"Requeued", "application/json", Schemas.WebhookDeliveryListResponse},
      409 => {"Refused", "application/problem+json", Schemas.Problem}
    }
  )

  def redeliver(conn, params) do
    job_id = Map.get(params, :id) || Map.get(params, "id")
    delivery_id = Map.get(params, :delivery_id) || Map.get(params, "delivery_id")
    actor = ApiConn.actor(conn)

    with {:ok, delivery} <- Webhooks.redeliver(job_id, delivery_id, actor) do
      ApiConn.audit(conn, conn.assigns[:current_token], "redeliver", job_id: job_id)

      conn
      |> put_status(:accepted)
      |> json(%{data: [delivery]})
    end
  end
end
