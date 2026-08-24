defmodule OmashikiWeb.RateLimiterTest do
  use ExUnit.Case, async: false

  alias OmashikiWeb.RateLimiter

  setup do
    RateLimiter.reset!()
    :ok
  end

  test "allows up to max hits inside a window" do
    for n <- 1..3 do
      assert {:ok, ^n} = RateLimiter.hit("scope", "1.2.3.4", max: 3, per_ms: 60_000)
    end
  end

  test "rejects the (max + 1)-th hit inside the same window" do
    Enum.each(1..3, fn _ ->
      RateLimiter.hit("scope", "1.2.3.4", max: 3, per_ms: 60_000)
    end)

    assert {:error, :rate_limited} =
             RateLimiter.hit("scope", "1.2.3.4", max: 3, per_ms: 60_000)
  end

  test "different identifiers do not share buckets" do
    Enum.each(1..3, fn _ ->
      RateLimiter.hit("scope", "1.2.3.4", max: 3, per_ms: 60_000)
    end)

    assert {:ok, 1} = RateLimiter.hit("scope", "5.6.7.8", max: 3, per_ms: 60_000)
  end

  test "different scopes do not share buckets" do
    Enum.each(1..3, fn _ ->
      RateLimiter.hit("scope_a", "x", max: 3, per_ms: 60_000)
    end)

    assert {:ok, 1} = RateLimiter.hit("scope_b", "x", max: 3, per_ms: 60_000)
  end

  test "windows expire" do
    assert {:ok, 1} = RateLimiter.hit("scope", "x", max: 1, per_ms: 1)
    Process.sleep(5)
    assert {:ok, 1} = RateLimiter.hit("scope", "x", max: 1, per_ms: 1)
  end
end
