defmodule Omashiki.Jobs.EventStream do
  @moduledoc """
  DB-backed SSE observation for one authorized job.

  The database remains the event and state authority. This module only reads
  committed events, emits them in sequence order, and keeps at most one page
  of events in memory while the socket applies backpressure.
  """

  import Ecto.Query
  import Plug.Conn

  alias Omashiki.Accounts.User
  alias Omashiki.ApiTokens.Token
  alias Omashiki.Jobs.{Job, JobEvent}
  alias Omashiki.Repo

  @terminal ~w(succeeded failed cancelled)
  @default_page_size 100
  @max_page_size 100
  @default_poll_interval_ms 1_000
  @default_heartbeat_interval_ms 15_000

  @doc "Authorize a job stream to its submitting token or its operator."
  def authorize(job_id, actor) when is_binary(job_id) do
    case Repo.get(Job, job_id) do
      nil ->
        {:error, :not_found}

      %Job{} = job ->
        if authorized_actor?(job, actor), do: {:ok, job}, else: {:error, :forbidden}
    end
  end

  def authorize(_, _), do: {:error, :not_found}

  @doc "Resolve and validate a Last-Event-ID cursor for one authorized job."
  def prepare(job_id, actor, last_event_id \\ nil) do
    with {:ok, job} <- authorize(job_id, actor),
         {:ok, after_sequence} <- cursor_sequence(job.id, last_event_id) do
      {:ok, %{job: job, after_sequence: after_sequence}}
    end
  end

  @doc "Fetch one bounded, retention-filtered page after a sequence cursor."
  def fetch_events(job_id, after_sequence, opts \\ [])
      when is_binary(job_id) and is_integer(after_sequence) and after_sequence >= 0 do
    limit = page_size(opts)
    cutoff = Keyword.get(opts, :cutoff, retention_cutoff())

    events =
      from(e in JobEvent,
        where:
          e.job_id == ^job_id and e.sequence > ^after_sequence and
            e.recorded_at >= ^cutoff,
        order_by: [asc: e.sequence],
        limit: ^limit
      )
      |> Repo.all()

    case contiguous?(events, after_sequence) do
      true -> {:ok, events}
      false -> {:error, :event_gap}
    end
  end

  @doc "Stream events and heartbeats until the client disconnects or the job ends."
  def stream(conn, %{id: job_id, status: status}, after_sequence, opts \\ []) do
    state = %{
      job_id: job_id,
      after_sequence: after_sequence,
      page_size: page_size(opts),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
      heartbeat_interval_ms:
        Keyword.get(opts, :heartbeat_interval_ms, @default_heartbeat_interval_ms),
      last_heartbeat_at: monotonic_ms(),
      max_polls: Keyword.get(opts, :max_polls, :infinity),
      polls: 0,
      terminal?: status in @terminal
    }

    stream_loop(conn, state)
  end

  @doc "Return the configured retention cutoff used by stream reads."
  def retention_cutoff(now \\ DateTime.utc_now(:microsecond)) do
    DateTime.add(now, -retention_days() * 86_400, :second)
  end

  @doc "Encode one persisted event as a single SSE event frame."
  def encode_event(%JobEvent{} = event) do
    payload = to_map(event)

    ["id: ", event.event_id, "\n", "event: job_event\n", "data: ", Jason.encode!(payload), "\n\n"]
    |> IO.iodata_to_binary()
  end

  @doc "Render an event without exposing persistence internals."
  def to_map(%JobEvent{} = event) do
    %{
      event_id: event.event_id,
      job_id: event.job_id,
      attempt: event.attempt,
      sequence: event.sequence,
      type: event.type,
      status: event.status,
      step: event.step,
      outcome: event.outcome,
      correlation_id: event.correlation_id,
      occurred_at: DateTime.to_iso8601(event.occurred_at),
      recorded_at: DateTime.to_iso8601(event.recorded_at),
      data: event.data,
      schema_version: event.schema_version
    }
  end

  def heartbeat_frame, do: ": heartbeat\n\n"

  defp cursor_sequence(_job_id, nil), do: {:ok, 0}
  defp cursor_sequence(_job_id, ""), do: {:error, :invalid_cursor}

  defp cursor_sequence(job_id, last_event_id) when is_binary(last_event_id) do
    with {:ok, event_id} <- cast_uuid(last_event_id),
         %JobEvent{} = event <- Repo.get(JobEvent, event_id) do
      cond do
        event.job_id != job_id ->
          {:error, :cursor_mismatch}

        DateTime.compare(event.recorded_at, retention_cutoff()) == :lt ->
          {:error, :cursor_expired}

        true ->
          {:ok, event.sequence}
      end
    else
      :error -> {:error, :invalid_cursor}
      nil -> {:error, :invalid_cursor}
    end
  end

  defp cursor_sequence(_, _), do: {:error, :invalid_cursor}

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp authorized_actor?(%Job{user_id: user_id, api_token_id: api_token_id}, %Token{
         id: token_id,
         user_id: user_id
       }) do
    token_id == api_token_id
  end

  defp authorized_actor?(%Job{user_id: user_id}, %User{id: user_id}), do: true
  defp authorized_actor?(_, _), do: false

  defp stream_loop(conn, state) do
    case fetch_events(state.job_id, state.after_sequence, page_size: state.page_size) do
      {:ok, []} ->
        if state.terminal? do
          conn
        else
          case maybe_heartbeat(conn, state) do
            {:error, :closed, conn} ->
              conn

            {:ok, conn, state} ->
              if poll_limit_reached?(state) do
                conn
              else
                Process.sleep(state.poll_interval_ms)
                stream_loop(conn, %{state | polls: state.polls + 1})
              end
          end
        end

      {:ok, events} ->
        case send_events(conn, events, state) do
          {:ok, conn, _state, true} -> conn
          {:ok, conn, state, false} -> stream_loop(conn, state)
          {:error, :closed, conn} -> conn
        end

      {:error, :event_gap} ->
        # Never manufacture a recovery event or advance state after a gap.
        conn
    end
  end

  defp send_events(conn, events, state) do
    Enum.reduce_while(events, {:ok, conn, state, false}, fn event,
                                                            {:ok, conn, state, _terminal} ->
      case chunk(conn, encode_event(event)) do
        {:ok, conn} ->
          state = %{state | after_sequence: event.sequence}

          if event.status in @terminal do
            {:halt, {:ok, conn, state, true}}
          else
            {:cont, {:ok, conn, state, false}}
          end

        {:error, :closed} ->
          {:halt, {:error, :closed, conn}}
      end
    end)
  end

  defp maybe_heartbeat(conn, state) do
    now = monotonic_ms()

    if now - state.last_heartbeat_at >= state.heartbeat_interval_ms do
      case chunk(conn, heartbeat_frame()) do
        {:ok, conn} -> {:ok, conn, %{state | last_heartbeat_at: now}}
        {:error, :closed} -> {:error, :closed, conn}
      end
    else
      {:ok, conn, state}
    end
  end

  defp contiguous?([], _after_sequence), do: true

  defp contiguous?([first | rest], 0), do: contiguous_from?(rest, first.sequence)

  defp contiguous?([first | rest], after_sequence) do
    first.sequence == after_sequence + 1 and contiguous_from?(rest, first.sequence)
  end

  defp contiguous_from?([], _sequence), do: true

  defp contiguous_from?([event | rest], sequence) do
    event.sequence == sequence + 1 and contiguous_from?(rest, event.sequence)
  end

  defp poll_limit_reached?(%{max_polls: :infinity}), do: false
  defp poll_limit_reached?(%{max_polls: max, polls: polls}), do: polls >= max

  defp page_size(opts) do
    opts
    |> Keyword.get(:page_size, @default_page_size)
    |> max(1)
    |> min(@max_page_size)
  end

  defp retention_days do
    case Application.get_env(:omashiki, :job_event_retention_days, 30) do
      days when is_integer(days) and days > 0 -> days
      _ -> 30
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
