defmodule OmashikiWeb.RateLimiter do
  @moduledoc """
  Tiny ETS-based fixed-window rate limiter. Used by
  `Api.SessionsController.issue_token/2` to make brute-forcing the
  credential exchange expensive.

  Reservations are taken atomically before password hashing, so a
  burst of connections cannot exceed `max`. A successful exchange
  refunds the reservation taken by that `hit/3` — even if the window
  rolled over during hashing — and does not consume the budget.
  Failures keep the count. Once the budget is spent, further attempts
  — including a correct password — are refused without hashing.
  Callers that share an IP therefore share the budget.

  Not a replacement for Hammer in production deploys that need
  cluster-wide coordination — this is intentionally local + dependency-free.
  Each bucket is keyed `(scope, identifier)` so different concerns can
  coexist without colliding.

  Usage:

      {:ok, _count, key} =
        RateLimiter.hit("issue_token", remote_ip, max: 10, per_ms: 60_000)

      RateLimiter.refund(key)
      # => :ok
  """

  @table __MODULE__

  @doc "Idempotently creates the underlying ETS table."
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:public, :named_table, :set, write_concurrency: true])

      _ ->
        :ok
    end
  end

  @doc """
  Records a hit for the given `(scope, identifier)` pair. Returns
  `{:ok, count, key}` when the bucket is still under `max`, or
  `{:error, :rate_limited}` when the limit has been reached for the
  current window.

  `key` identifies the window that was reserved so `refund/1` can
  return that slot even after the clock crosses into the next window.
  """
  def hit(scope, identifier, opts) when is_binary(scope) do
    ensure_table()

    max = Keyword.fetch!(opts, :max)
    per_ms = Keyword.fetch!(opts, :per_ms)
    now = System.system_time(:millisecond)
    window = div(now, per_ms)
    key = {scope, identifier, window}

    n = :ets.update_counter(@table, key, {2, 1}, {key, 0})
    maybe_gc(scope, window)

    if n > max do
      rollback(key)
      {:error, :rate_limited}
    else
      {:ok, n, key}
    end
  end

  @doc """
  Give back the reservation identified by `key` from `hit/3`.

  Used when the work that reserved a slot succeeded and must not consume
  the failure budget. A missing key (GC after rollover, or a double
  refund) is a no-op.
  """
  def refund(key) when is_tuple(key) do
    ensure_table()
    rollback(key)
    :ok
  end

  @doc """
  Increment a concurrent-use counter. Returns `{:ok, count}` or
  `{:error, :rate_limited}` when `max` is already held.
  """
  def checkout(scope, identifier, max) when is_binary(scope) and is_integer(max) and max > 0 do
    ensure_table()
    key = {:conc, scope, identifier}

    case :ets.update_counter(@table, key, {2, 1}, {key, 0}) do
      n when n > max ->
        rollback(key)
        {:error, :rate_limited}

      n ->
        {:ok, n}
    end
  end

  @doc "Decrement a concurrent-use counter opened by `checkout/3`."
  def checkin(scope, identifier) when is_binary(scope) do
    ensure_table()
    rollback({:conc, scope, identifier})
    :ok
  end

  @doc "Test helper — clears every bucket."
  def reset! do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  # Decrement without inserting a missing row. `maybe_gc` on a newer window
  # can delete this key between increment and rollback; that must not 500.
  defp rollback(key) do
    try do
      n = :ets.update_counter(@table, key, {2, -1, 0, 0})
      if n == 0, do: :ets.select_delete(@table, [{{key, 0}, [], [true]}])
      n
    rescue
      ArgumentError -> 0
    end
  end

  # One table scan per (scope, window), not per hit. The sentinel is itself
  # collected when a later window wins the same insert_new race.
  defp maybe_gc(scope, window) do
    gc_key = {:gc, scope, window}

    if :ets.insert_new(@table, {gc_key, true}) do
      :ets.select_delete(@table, [
        {{{scope, :"$1", :"$2"}, :_}, [{:<, :"$2", window}], [true]},
        {{{:gc, scope, :"$1"}, :_}, [{:<, :"$1", window}], [true]}
      ])
    end
  end
end
