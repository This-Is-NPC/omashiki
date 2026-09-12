defmodule OmashikiWeb.Api.WorkController do
  use OmashikiWeb, :controller

  action_fallback OmashikiWeb.FallbackController

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
    end
  end

  def poll(conn, params) do
    with {:ok, machine_id} <- required_string(params, "machine_id"),
         {:ok, free_slots} <- parse_free_slots(params["free_slots"]),
         {:ok, payload} <- Inbox.poll(machine_id, free_slots) do
      json(conn, payload)
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
    end
  end

  def heartbeat(conn, params) do
    with {:ok, attempt_id} <- required_string(params, "attempt_id"),
         {:ok, lease_token} <- required_string(params, "lease_token"),
         {:ok, status} <- Inbox.heartbeat(attempt_id, lease_token) do
      json(conn, %{cancel: status == :cancel})
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
    end
  end

  def reject(conn, params) do
    with {:ok, attempt_id} <- required_string(params, "attempt_id"),
         {:ok, lease_token} <- required_string(params, "lease_token"),
         {:ok, :ok} <- Inbox.reject(attempt_id, lease_token) do
      json(conn, %{ok: true})
    end
  end

  def complete(conn, params) do
    with {:ok, attempt_id} <- required_string(params, "attempt_id"),
         {:ok, lease_token} <- required_string(params, "lease_token"),
         %{} = complete_map <- Map.get(params, "complete") || {:error, :invalid_complete},
         :ok <- complete_attempt(attempt_id, lease_token, complete_map) do
      json(conn, %{ok: true})
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
      nil -> {:error, :missing_digest}
      {:error, :digest_mismatch} -> {:error, :digest_mismatch}
      {:error, reason} -> {:error, reason}
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
end
