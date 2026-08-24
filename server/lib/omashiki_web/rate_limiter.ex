defmodule OmashikiWeb.RateLimiter do
  @moduledoc """
  Tiny ETS-based fixed-window rate limiter. Used by
  `Api.SessionsController.issue_token/2` to make brute-forcing the
  credential exchange endpoint expensive.

  Not a replacement for Hammer in production deploys that need
  cluster-wide coordination — this is intentionally local + dependency-free.
  Each bucket is keyed `(scope, identifier)` so different concerns can
  coexist without colliding.

  Usage:

      RateLimiter.hit("issue_token", remote_ip, max: 10, per_ms: 60_000)
      # => {:ok, count} | {:error, :rate_limited}
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
  `{:ok, count}` when the bucket is still under `max`, or
  `{:error, :rate_limited}` when the limit has been reached for the
  current window.
  """
  def hit(scope, identifier, opts) when is_binary(scope) do
    ensure_table()

    max = Keyword.fetch!(opts, :max)
    per_ms = Keyword.fetch!(opts, :per_ms)
    now = System.system_time(:millisecond)
    window_start = now - per_ms

    key = {scope, identifier}

    case :ets.lookup(@table, key) do
      [{^key, started_at, count}] when started_at > window_start ->
        if count >= max do
          {:error, :rate_limited}
        else
          :ets.insert(@table, {key, started_at, count + 1})
          {:ok, count + 1}
        end

      _ ->
        :ets.insert(@table, {key, now, 1})
        {:ok, 1}
    end
  end

  @doc "Test helper — clears every bucket."
  def reset! do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end
end
