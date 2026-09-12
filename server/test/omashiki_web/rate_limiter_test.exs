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

  test "skipped windows do not accumulate keys" do
    assert {:ok, 1} = RateLimiter.hit("scope", "x", max: 1, per_ms: 1)
    Process.sleep(5)
    assert {:ok, 1} = RateLimiter.hit("scope", "x", max: 1, per_ms: 1)
    Process.sleep(5)
    assert {:ok, 1} = RateLimiter.hit("scope", "x", max: 1, per_ms: 1)
    assert bucket_count("scope") == 1
  end

  test "expired windows for other identifiers are collected" do
    assert {:ok, 1} = RateLimiter.hit("scope", "old", max: 1, per_ms: 1)
    Process.sleep(5)
    assert {:ok, 1} = RateLimiter.hit("scope", "new", max: 1, per_ms: 1)
    assert bucket_count("scope") == 1
  end

  test "concurrent hits share one atomic counter" do
    results =
      1..40
      |> Task.async_stream(
        fn _ -> RateLimiter.hit("conc", "same", max: 10, per_ms: 60_000) end,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 10
    assert Enum.count(results, &match?({:error, :rate_limited}, &1)) == 30
  end

  test "checkin removes a zeroed counter" do
    assert {:ok, 1} = RateLimiter.checkout("conc", "id", 2)
    RateLimiter.checkin("conc", "id")
    assert conc_count() == 0
  end

  test "checkin does not drop a remaining checkout" do
    assert {:ok, 1} = RateLimiter.checkout("conc", "id", 2)
    assert {:ok, 2} = RateLimiter.checkout("conc", "id", 2)
    RateLimiter.checkin("conc", "id")
    assert {:ok, 2} = RateLimiter.checkout("conc", "id", 2)
  end

  defp bucket_count(scope) do
    :ets.select_count(RateLimiter, [{{{scope, :"$1", :"$2"}, :_}, [], [true]}])
  end

  defp conc_count do
    :ets.select_count(RateLimiter, [{{{:conc, :"$1", :"$2"}, :_}, [], [true]}])
  end
end
