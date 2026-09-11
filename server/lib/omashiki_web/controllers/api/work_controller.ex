defmodule OmashikiWeb.Api.WorkController do
  use OmashikiWeb, :controller

  alias Omashiki.Fleet
  alias Omashiki.Worker.{Inbox, Presence}

  def register(conn, params) do
    with {:ok, machine_id} <- required_string(params, "machine_id"),
         {:ok, free_slots} <- parse_free_slots(params["free_slots"]) do
      metadata =
        case params["images"] do
          images when is_list(images) -> %{images: images}
          _ -> %{}
        end

      :ok = Presence.touch(machine_id, %{free_slots: free_slots, metadata: metadata})
      send_resp(conn, :no_content, "")
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def poll(conn, params) do
    with {:ok, machine_id} <- required_string(params, "machine_id"),
         {:ok, free_slots} <- parse_free_slots(params["free_slots"]),
         {:ok, payload} <- Inbox.poll(machine_id, free_slots) do
      json(conn, payload)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  # Slots, capacity, and the containers the worker runs for this house. It is
  # what the fleet view draws; it grants nothing and changes no job.
  def report(conn, params) do
    with {:ok, machine_id} <- required_string(params, "machine_id"),
         {:ok, free_slots} <- parse_free_slots(params["free_slots"]),
         {:ok, capacity} <- parse_capacity(params["capacity"]),
         {:ok, containers} <- Fleet.parse_containers(params["containers"]) do
      :ok =
        Presence.report(machine_id, %{
          free_slots: free_slots,
          capacity: capacity,
          containers: containers
        })

      send_resp(conn, :no_content, "")
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def heartbeat(conn, params) do
    with {:ok, attempt_id} <- required_string(params, "attempt_id"),
         {:ok, lease_token} <- required_string(params, "lease_token"),
         {:ok, status} <- Inbox.heartbeat(attempt_id, lease_token) do
      json(conn, %{cancel: status == :cancel})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def accept(conn, params) do
    with {:ok, attempt_id} <- required_string(params, "attempt_id"),
         {:ok, lease_token} <- required_string(params, "lease_token"),
         {:ok, status} <- Inbox.accept(attempt_id, lease_token) do
      if status == :cancel do
        json(conn, %{cancel: true})
      else
        json(conn, %{ok: true})
      end
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def reject(conn, params) do
    with {:ok, attempt_id} <- required_string(params, "attempt_id"),
         {:ok, lease_token} <- required_string(params, "lease_token"),
         {:ok, :ok} <- Inbox.reject(attempt_id, lease_token) do
      json(conn, %{ok: true})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def complete(conn, params) do
    with {:ok, attempt_id} <- required_string(params, "attempt_id"),
         {:ok, lease_token} <- required_string(params, "lease_token"),
         %{} = complete_map <- Map.get(params, "complete") || {:error, :invalid_complete},
         :ok <- complete_attempt(attempt_id, lease_token, complete_map) do
      json(conn, %{ok: true})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def put_blob(conn, %{"job_id" => job_id}) do
    digest =
      case get_req_header(conn, "x-omashiki-digest") do
        [value | _] -> value
        _ -> nil
      end

    with digest when is_binary(digest) <- digest,
         {:ok, body, _conn} <- read_body(conn),
         {:ok, path} <- Inbox.put_blob(job_id, digest, body) do
      conn
      |> put_status(:created)
      |> json(%{path: path, digest: digest})
    else
      nil -> error(conn, :missing_digest)
      {:error, :digest_mismatch} -> error(conn, :digest_mismatch)
      {:error, reason} -> error(conn, reason)
    end
  end

  defp complete_attempt(attempt_id, lease_token, complete_map) do
    case Inbox.complete(attempt_id, lease_token, complete_map) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp required_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:validation, key}}
    end
  end

  defp parse_free_slots(nil), do: {:ok, 0}
  defp parse_free_slots(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp parse_free_slots(value) when is_binary(value) do
    case Integer.parse(value) do
      {slots, ""} when slots >= 0 -> {:ok, slots}
      _ -> {:error, :invalid_free_slots}
    end
  end

  defp parse_free_slots(_), do: {:error, :invalid_free_slots}

  defp parse_capacity(nil), do: {:ok, nil}
  defp parse_capacity(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp parse_capacity(_), do: {:error, :invalid_capacity}

  defp error(conn, :invalid_capacity),
    do: error_response(conn, 422, "invalid_capacity", "capacity must be a non-negative integer")

  defp error(conn, :invalid_containers),
    do: error_response(conn, 422, "invalid_containers", "containers must be a valid report list")

  defp error(conn, :missing_digest),
    do: error_response(conn, 400, "missing_digest", "x-omashiki-digest header is required")

  defp error(conn, :digest_mismatch),
    do: error_response(conn, 400, "digest_mismatch", "Digest does not match request body")

  defp error(conn, :invalid_complete),
    do: error_response(conn, 422, "invalid_complete", "Complete payload is required")

  defp error(conn, :invalid_free_slots),
    do:
      error_response(conn, 422, "invalid_free_slots", "free_slots must be a non-negative integer")

  defp error(conn, {:validation, field}),
    do:
      error_response(conn, 422, "invalid_request", "Request validation failed", %{
        field: field
      })

  defp error(conn, :not_found), do: error_response(conn, 404, "not_found", "Attempt not found")

  defp error(conn, :blob_missing),
    do: error_response(conn, 409, "blob_missing", "Blob was not uploaded for this job")

  defp error(conn, :stale_lease),
    do: error_response(conn, 409, "stale_lease", "Lease token is no longer valid")

  defp error(conn, :lease_expired),
    do: error_response(conn, 409, "lease_expired", "Lease has expired")

  defp error(conn, :attempt_not_active),
    do: error_response(conn, 409, "attempt_not_active", "Attempt is not active")

  defp error(conn, :already_running),
    do: error_response(conn, 409, "already_running", "Attempt is already running")

  defp error(conn, :invalid_success_result),
    do: error_response(conn, 422, "invalid_success_result", "Success payload is invalid")

  defp error(conn, _reason),
    do: error_response(conn, 500, "internal_error", "Request could not be completed")

  defp error_response(conn, status, code, message, details \\ %{}) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message, details: details}})
  end
end
