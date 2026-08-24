defmodule Omashiki.Jobs.Webhooks do
  @moduledoc """
  Signed terminal webhook contract and durable outbox operations.

  A webhook belongs to an API token. Job input never supplies a destination.
  Delivery is at-least-once: clients must deduplicate by `event_id`.
  """

  import Ecto.Query

  alias Omashiki.ApiTokens.Token
  alias Omashiki.Jobs.{Job, JobAttempt, JobEvent, WebhookDelivery, WebhookDeliveryWorker}
  alias Omashiki.Repo
  alias Omashiki.Security.Network

  @retry_window_seconds 24 * 60 * 60
  @max_timestamp_age_seconds 300
  @default_timeout_ms 5_000
  @redirect_statuses 300..399

  @doc "Configure a token-owned destination and signing secret, rotating one prior key."
  def configure(%Token{} = token, attrs) when is_map(attrs) do
    destination = attr(attrs, :destination) || attr(attrs, :webhook_destination)
    secret = attr(attrs, :secret) || attr(attrs, :webhook_secret)
    key_id = attr(attrs, :key_id) || attr(attrs, :webhook_key_id) || "v1"

    with {:ok, destination} <- validate_destination(destination),
         :ok <- validate_secret(secret),
         :ok <- validate_key_id(key_id),
         {:ok, configured} <- persist_configuration(token, destination, secret, key_id) do
      {:ok, configured}
    end
  end

  def configure(_, _), do: {:error, :invalid_webhook_configuration}

  @doc "Validate and normalize a token-owned HTTP(S) destination."
  def validate_destination(destination) when is_binary(destination) do
    uri = URI.parse(String.trim(destination))

    cond do
      uri.scheme not in ["http", "https"] -> {:error, :invalid_destination_scheme}
      is_nil(uri.host) or uri.host == "" -> {:error, :invalid_destination_host}
      uri.userinfo -> {:error, :destination_userinfo_not_allowed}
      uri.fragment -> {:error, :destination_fragment_not_allowed}
      invalid_port?(uri.port) -> {:error, :invalid_destination_port}
      private_host?(uri.host) -> {:error, :private_destination_not_allowed}
      true -> {:ok, normalized_destination(uri)}
    end
  end

  def validate_destination(_), do: {:error, :invalid_destination}

  @doc "Build the fixed terminal payload signed by the delivery worker."
  def payload(%Job{} = job, %JobAttempt{} = attempt, %JobEvent{} = event) do
    %{
      "schema_version" => 1,
      "event_id" => event.event_id,
      "timestamp" => DateTime.to_iso8601(event.occurred_at),
      "job_id" => job.id,
      "attempt_id" => attempt.id,
      "attempt" => attempt.number,
      "status" => event.status,
      "correlation_id" => job.correlation_id,
      "git" => %{
        "branch" => attempt.branch,
        "base_sha" => attempt.base_sha,
        "head_sha" => attempt.head_sha,
        "worktree_clean" => attempt.worktree_clean
      }
    }
  end

  @doc "Return deterministic JSON with recursively sorted object keys."
  def canonical_json(value), do: encode_canonical(value)

  @doc "Sign a canonical payload using the timestamp-bound v1 HMAC format."
  def sign(payload, secret) when is_map(payload) and is_binary(secret) do
    signature_input(payload)
    |> then(&:crypto.mac(:hmac, :sha256, secret, &1))
    |> Base.encode16(case: :lower)
    |> then(&"v1=#{&1}")
  end

  @doc "Verify signature, timestamp freshness, and the rotating current/previous key set."
  def verify(payload, signature, secrets, opts \\ [])

  def verify(payload, signature, secrets, opts)
      when is_map(payload) and is_binary(signature) and is_list(secrets) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:second))
    max_age = Keyword.get(opts, :max_age_seconds, @max_timestamp_age_seconds)

    with {:ok, timestamp} <- timestamp(payload),
         true <- abs(DateTime.diff(now, timestamp, :second)) <= max_age do
      case signature_hex(signature) do
        {:ok, expected} ->
          if Enum.any?(secrets, &secure_compare(expected, signature_hex_for(payload, &1))),
            do: {:ok, :valid},
            else: {:error, :invalid_signature}

        _ ->
          {:error, :invalid_signature}
      end
    else
      false -> {:error, :replay_or_expired}
      _ -> {:error, :invalid_signature}
    end
  end

  def verify(payload, signature, secret, opts) when is_binary(secret),
    do: verify(payload, signature, [secret], opts)

  @doc "Insert one terminal event's outbox row and its Oban dispatcher atomically."
  def enqueue_for_event!(%Job{} = job, %JobAttempt{} = attempt, %JobEvent{} = event) do
    case Repo.get(Token, job.api_token_id) do
      %Token{} = token
      when is_binary(token.webhook_destination) and is_binary(token.webhook_secret_ciphertext) ->
        destination = token.webhook_destination
        ciphertext = token.webhook_secret_ciphertext

        with {:ok, destination} <- validate_destination(destination),
             {:ok, _secret} <- decrypt_secret(ciphertext) do
          payload = payload(job, attempt, event)
          body = canonical_json(payload)
          now = DateTime.utc_now(:microsecond)
          key_id = token.webhook_key_id || "v1"

          attrs = %{
            event_id: event.event_id,
            destination: destination,
            idempotency_key: event.event_id,
            status: "pending",
            attempts: 0,
            next_attempt_at: now,
            payload: payload,
            payload_hash: digest(body),
            signing_key_id: key_id,
            signing_secret_ciphertext: ciphertext
          }

          case insert_delivery(attrs) do
            {:duplicate, _delivery} ->
              :ok

            {:ok, delivery} ->
              case Oban.insert(
                     WebhookDeliveryWorker.new(%{"delivery_id" => delivery.id},
                       scheduled_at: now
                     )
                   ) do
                {:ok, _job} -> :ok
                {:error, changeset} -> Repo.rollback({:webhook_dispatch, changeset})
              end
          end
        else
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  @doc "Deliver one due outbox row; failures schedule exponential retry or dead-letter."
  def deliver(delivery_id, opts \\ []) when is_binary(delivery_id) do
    case claim_delivery(delivery_id) do
      {:ok, :skip, status} ->
        {:ok, delivery_status_atom(status)}

      {:ok, :dead} ->
        {:ok, :dead}

      {:ok, delivery} ->
        result = dispatch(delivery, opts)
        finish_delivery(delivery, result)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc "List redacted delivery state for an authorized job operator."
  def list_for_job(job_id, actor) when is_binary(job_id) do
    with {:ok, _job} <- Omashiki.Jobs.EventStream.authorize(job_id, actor) do
      deliveries =
        from(d in WebhookDelivery,
          join: e in JobEvent,
          on: e.event_id == d.event_id,
          where: e.job_id == ^job_id,
          order_by: [desc: d.inserted_at]
        )
        |> Repo.all()

      {:ok, Enum.map(deliveries, &status/1)}
    end
  end

  def list_for_job(_, _), do: {:error, :not_found}

  @doc "Return operator-safe delivery fields without payloads or key material."
  def status(%WebhookDelivery{} = delivery) do
    %{
      id: delivery.id,
      event_id: delivery.event_id,
      destination: delivery.destination,
      status: delivery.status,
      attempts: delivery.attempts,
      next_attempt_at: delivery.next_attempt_at,
      delivered_at: delivery.delivered_at,
      last_response_status: delivery.last_response_status,
      last_error: delivery.last_error,
      inserted_at: delivery.inserted_at,
      updated_at: delivery.updated_at
    }
  end

  defp persist_configuration(token, destination, secret, key_id) do
    Repo.transaction(fn ->
      persisted =
        from(t in Token, where: t.id == ^token.id, lock: "FOR UPDATE")
        |> Repo.one()

      if is_nil(persisted), do: Repo.rollback(:not_found)

      if is_nil(secret) and is_nil(persisted.webhook_secret_ciphertext),
        do: Repo.rollback(:webhook_secret_required)

      attrs =
        %{webhook_destination: destination}
        |> rotate_secret(persisted, secret, key_id)

      case persisted |> Token.webhook_changeset(attrs) |> Repo.update() do
        {:ok, updated} -> updated
        {:error, changeset} -> Repo.rollback({:persistence, changeset})
      end
    end)
  end

  defp rotate_secret(attrs, _token, nil, _key_id), do: attrs

  defp rotate_secret(attrs, token, secret, key_id) do
    attrs
    |> Map.put(:webhook_secret_ciphertext, encrypt_secret(secret))
    |> Map.put(:webhook_key_id, key_id)
    |> Map.put(:webhook_previous_secret_ciphertext, token.webhook_secret_ciphertext)
    |> Map.put(:webhook_previous_key_id, token.webhook_key_id)
  end

  defp claim_delivery(id) do
    Repo.transaction(fn ->
      case from(d in WebhookDelivery, where: d.id == ^id, lock: "FOR UPDATE") |> Repo.one() do
        nil ->
          Repo.rollback(:not_found)

        %WebhookDelivery{status: status} when status in ["delivered", "dead"] ->
          {:skip, status}

        %WebhookDelivery{status: "delivering"} ->
          {:skip, "delivering"}

        %WebhookDelivery{} = delivery ->
          now = DateTime.utc_now(:microsecond)

          cond do
            DateTime.compare(now, delivery.next_attempt_at) == :lt ->
              {:skip, "pending"}

            DateTime.compare(now, deadline(delivery)) != :lt ->
              update_delivery!(delivery, %{
                status: "dead",
                next_attempt_at: now,
                last_error: error("retry_window_expired")
              })

              :dead

            true ->
              update_delivery!(delivery, %{
                status: "delivering",
                attempts: delivery.attempts + 1,
                last_error: nil
              })
          end
      end
    end)
    |> case do
      {:ok, {:skip, status}} -> {:ok, :skip, status}
      {:ok, :dead} -> {:ok, :dead}
      {:ok, %WebhookDelivery{} = delivery} -> {:ok, delivery}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp finish_delivery(%WebhookDelivery{} = delivery, {:ok, status}) when status in 200..299 do
    now = DateTime.utc_now(:microsecond)

    Repo.transaction(fn ->
      current = locked_delivery!(delivery.id)

      update_delivery!(current, %{
        status: "delivered",
        delivered_at: now,
        last_response_status: status
      })

      :delivered
    end)
    |> unwrap_result()
  end

  defp finish_delivery(%WebhookDelivery{} = delivery, {:ok, status})
       when status in @redirect_statuses do
    finish_failure(delivery, :redirect_rejected, status)
  end

  defp finish_delivery(%WebhookDelivery{} = delivery, {:ok, status}),
    do: finish_failure(delivery, {:http_status, status}, status)

  defp finish_delivery(%WebhookDelivery{} = delivery, {:error, reason}),
    do: finish_failure(delivery, reason, nil)

  defp finish_failure(delivery, reason, response_status) do
    Repo.transaction(fn ->
      current = locked_delivery!(delivery.id)
      now = DateTime.utc_now(:microsecond)
      next = DateTime.add(now, backoff_seconds(current.attempts), :second)

      if DateTime.compare(next, deadline(current)) != :lt do
        update_delivery!(current, %{
          status: "dead",
          next_attempt_at: now,
          last_response_status: response_status,
          last_error: error(reason)
        })

        :dead
      else
        updated =
          update_delivery!(current, %{
            status: "failed",
            next_attempt_at: next,
            last_response_status: response_status,
            last_error: error(reason)
          })

        {:retry, updated.next_attempt_at}
      end
    end)
    |> unwrap_result()
  end

  defp dispatch(%WebhookDelivery{} = delivery, opts) do
    with {:ok, secret} <- decrypt_secret(delivery.signing_secret_ciphertext),
         {:ok, destination} <- validate_destination(delivery.destination) do
      body = canonical_json(delivery.payload)
      expected_hash = digest(body)

      if secure_compare(expected_hash, delivery.payload_hash) do
        headers = [
          {"content-type", "application/json"},
          {"user-agent", "omashiki-webhooks/1"},
          {"idempotency-key", delivery.idempotency_key},
          {"x-webhook-event-id", delivery.event_id},
          {"x-webhook-timestamp", delivery.payload["timestamp"]},
          {"x-webhook-key-id", delivery.signing_key_id || "v1"},
          {"x-webhook-signature", sign(delivery.payload, secret)}
        ]

        transport = Keyword.get(opts, :transport)

        case transport do
          fun when is_function(fun, 3) -> normalize_transport(fun.(destination, headers, body))
          _ -> mint_post(destination, headers, body, opts)
        end
      else
        {:error, :payload_tampered}
      end
    end
  end

  defp normalize_transport({:ok, status}) when is_integer(status), do: {:ok, status}
  defp normalize_transport({:ok, %{status: status}}) when is_integer(status), do: {:ok, status}
  defp normalize_transport({status, _headers, _body}) when is_integer(status), do: {:ok, status}
  defp normalize_transport({:error, reason}), do: {:error, reason}
  defp normalize_transport(_), do: {:error, :invalid_transport_response}

  defp mint_post(destination, headers, body, opts) do
    uri = URI.parse(destination)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    port = uri.port || if(uri.scheme == "https", do: 443, else: 80)
    scheme = String.to_atom(uri.scheme)
    transport_opts = if scheme == :https, do: [verify: :verify_peer], else: []

    with :ok <- Network.authorize_host(uri.host),
         {:ok, conn} <-
           Mint.HTTP.connect(scheme, uri.host, port,
             mode: :passive,
             transport_opts: transport_opts
           ),
         {:ok, conn, _ref} <- Mint.HTTP.request(conn, "POST", request_path(uri), headers, body),
         result <- recv_response(conn, System.monotonic_time(:millisecond) + timeout, []) do
      result
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp recv_response(conn, deadline, responses) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    case Mint.HTTP.recv(conn, 0, timeout) do
      {:ok, conn, received} ->
        responses = responses ++ received

        cond do
          Enum.any?(responses, &redirect_response?/1) ->
            Mint.HTTP.close(conn)
            {:error, :redirect_rejected}

          Enum.any?(received, &match?({:done, _}, &1)) ->
            Mint.HTTP.close(conn)
            {:ok, response_status(responses)}

          timeout == 0 ->
            Mint.HTTP.close(conn)
            {:error, :timeout}

          true ->
            recv_response(conn, deadline, responses)
        end

      {:error, conn, reason, _received} ->
        Mint.HTTP.close(conn)
        {:error, reason}
    end
  end

  defp redirect_response?({:status, _ref, status}), do: status in @redirect_statuses
  defp redirect_response?(_), do: false

  defp response_status(responses),
    do:
      Enum.find_value(responses, fn
        {tag, _ref, status} when tag == :status -> status
        _ -> nil
      end)

  defp request_path(uri) do
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    if uri.query, do: path <> "?" <> uri.query, else: path
  end

  defp insert_delivery(attrs) do
    case %WebhookDelivery{} |> WebhookDelivery.changeset(attrs) |> Repo.insert() do
      {:ok, delivery} ->
        {:ok, delivery}

      {:error, changeset} ->
        if unique_error?(changeset) do
          {:duplicate,
           Repo.get_by(WebhookDelivery, event_id: attrs.event_id, destination: attrs.destination)}
        else
          Repo.rollback({:webhook_persistence, changeset})
        end
    end
  end

  defp unique_error?(%Ecto.Changeset{errors: errors}),
    do: Enum.any?(errors, fn {_field, {_message, opts}} -> opts[:constraint] == :unique end)

  defp unique_error?(_), do: false

  defp locked_delivery!(id),
    do: from(d in WebhookDelivery, where: d.id == ^id, lock: "FOR UPDATE") |> Repo.one!()

  defp update_delivery!(delivery, attrs) do
    case delivery |> WebhookDelivery.changeset(attrs) |> Repo.update() do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback({:webhook_persistence, changeset})
    end
  end

  defp unwrap_result({:ok, value}) when value in [:delivered, :dead], do: {:ok, value}
  defp unwrap_result({:ok, {:retry, _} = retry}), do: retry
  defp unwrap_result({:error, reason}), do: {:error, reason}

  defp deadline(delivery), do: DateTime.add(delivery.inserted_at, @retry_window_seconds, :second)
  defp backoff_seconds(attempts), do: min(trunc(:math.pow(2, max(attempts - 1, 0))), 3_600)

  defp error({:http_status, status}), do: %{"code" => "http_error", "status" => status}
  defp error(reason) when is_atom(reason), do: %{"code" => Atom.to_string(reason)}
  defp error(reason) when is_binary(reason), do: %{"code" => String.slice(reason, 0, 120)}
  defp error(_), do: %{"code" => "delivery_failed"}

  defp delivery_status_atom("delivered"), do: :delivered
  defp delivery_status_atom("dead"), do: :dead
  defp delivery_status_atom("pending"), do: :pending
  defp delivery_status_atom("delivering"), do: :delivering
  defp delivery_status_atom("failed"), do: :failed
  defp delivery_status_atom(_), do: :unknown

  defp timestamp(%{"timestamp" => value}),
    do: DateTime.from_iso8601(value) |> normalize_timestamp()

  defp timestamp(_), do: {:error, :timestamp_required}
  defp normalize_timestamp({:ok, timestamp, 0}), do: {:ok, timestamp}
  defp normalize_timestamp(_), do: {:error, :invalid_timestamp}

  defp signature_input(payload), do: payload["timestamp"] <> "." <> canonical_json(payload)

  defp signature_hex(signature) do
    case Regex.run(~r/^v1=([0-9a-f]{64})$/, signature) do
      [_, hex] -> {:ok, hex}
      _ -> {:error, :invalid_signature}
    end
  end

  defp signature_hex_for(payload, secret),
    do: sign(payload, secret) |> String.replace_prefix("v1=", "")

  defp secure_compare(left, right),
    do: byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)

  defp encrypt_secret(secret) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, encryption_key(), iv, secret, "webhook", true)

    Base.encode64(iv <> tag <> ciphertext)
  end

  defp decrypt_secret(ciphertext) when is_binary(ciphertext) do
    with {:ok, encoded} <- Base.decode64(ciphertext),
         <<iv::binary-size(12), tag::binary-size(16), encrypted::binary>> <- encoded,
         plaintext <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             encryption_key(),
             iv,
             encrypted,
             "webhook",
             tag,
             false
           ),
         true <- is_binary(plaintext) do
      {:ok, plaintext}
    else
      _ -> {:error, :invalid_secret_ciphertext}
    end
  end

  defp decrypt_secret(_), do: {:error, :missing_secret}

  defp encryption_key do
    endpoint = Application.fetch_env!(:omashiki, OmashikiWeb.Endpoint)
    :crypto.hash(:sha256, Keyword.fetch!(endpoint, :secret_key_base))
  end

  defp validate_secret(nil), do: :ok
  defp validate_secret(secret) when is_binary(secret) and byte_size(secret) >= 8, do: :ok
  defp validate_secret(_), do: {:error, :webhook_secret_required}
  defp validate_key_id(value) when is_binary(value) and byte_size(value) in 1..80, do: :ok
  defp validate_key_id(_), do: {:error, :invalid_webhook_key_id}

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp invalid_port?(nil), do: false
  defp invalid_port?(port), do: not (is_integer(port) and port in 1..65_535)

  defp normalized_destination(uri) do
    uri
    |> Map.put(:scheme, String.downcase(uri.scheme))
    |> Map.put(:host, String.downcase(uri.host))
    |> URI.to_string()
  end

  defp private_host?(host) do
    host = String.downcase(host)

    host in ["localhost", "localhost.localdomain"] or String.ends_with?(host, ".localhost") or
      String.ends_with?(host, ".local") or private_ip?(host) or
      Network.authorize_host(host) == {:error, :restricted_destination}
  end

  defp private_ip?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> not Network.public_address?(address)
      _ -> false
    end
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp encode_canonical(%{} = map) do
    entries =
      map
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Enum.sort_by(&elem(&1, 0))

    "{" <>
      Enum.map_join(entries, ",", fn {key, value} ->
        Jason.encode!(key) <> ":" <> encode_canonical(value)
      end) <> "}"
  end

  defp encode_canonical(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &encode_canonical/1) <> "]"

  defp encode_canonical(value), do: Jason.encode!(value)
end
