# Settles the inline-vs-async question for `Omashiki.ApiTokens.record_use/1`
# with a measurement instead of a preference.
#
#   MIX_ENV=test OMASHIKI_DB_PORT=5442 MIX_TEST_PARTITION=93 \
#     mix run bench/record_use_bench.exs
#
# Workload: the load-test shape — N concurrent callers all presenting the SAME
# api token, so every write targets one hot row. Each iteration does what
# `BearerAuth` does: look the token up, then record the use.
#
# Arms. The three statements are written out here rather than called through
# `ApiTokens`, so the benchmark keeps measuring the same three things after the
# module is refactored:
#
#   :none           no write at all — the floor, to size the other three
#   :unconditional  inline `UPDATE ... WHERE id = $1`          (the pre-fix defect)
#   :guarded        inline, plus the @use_resolution predicate (the dissent)
#   :async          the guarded statement off the caller's process (the majority)
#
# Reported per arm: caller-visible latency percentiles for the record_use step
# (what an API request actually pays), wall time to *drain* all the work — async
# is only allowed to look cheap if the work still finishes — and pool errors,
# split into the record_use step and the token lookup that shares its pool.
#
# NOTE ON THE POOL. `config/test.exs` configures `Ecto.Adapters.SQL.Sandbox`,
# whose `:auto` mode still hands each *process* an owned connection for its
# whole lifetime. 400 long-lived workers would therefore pin 400 connections
# and deadlock a 24-slot pool before any arm ran. So the bench starts a second,
# dynamic instance of the same repo on a plain `DBConnection.ConnectionPool`
# and every process opts into it with `put_dynamic_repo/1`.

import Ecto.Query

alias Omashiki.ApiTokens
alias Omashiki.ApiTokens.Token
alias Omashiki.Accounts
alias Omashiki.Repo

Logger.configure(level: :error)

workers = String.to_integer(System.get_env("BENCH_WORKERS") || "400")
iterations = String.to_integer(System.get_env("BENCH_ITERATIONS") || "25")
reps = String.to_integer(System.get_env("BENCH_REPS") || "3")
pool_size = String.to_integer(System.get_env("BENCH_POOL_SIZE") || "24")
use_resolution = 60

total_calls = workers * iterations

# ------------------------------------------------------------------- pool ---

bench_repo_config =
  :omashiki
  |> Application.get_env(Repo)
  |> Keyword.drop([:pool, :pool_size, :name])
  |> Keyword.merge(name: :bench_repo, pool_size: pool_size)

{:ok, _} = Repo.start_link(bench_repo_config)
Repo.put_dynamic_repo(:bench_repo)

# ---------------------------------------------------------------- fixtures --

# The bench shares the test database with the suite, and `Accounts` refuses to
# register a second user — so a bench run that was interrupted before its
# teardown would fail every signup test afterwards. Clear our own leftovers
# first; the username prefix keeps this away from anything the suite owns.
Repo.delete_all(
  from t in Token,
    join: u in Accounts.User,
    on: u.id == t.user_id,
    where: like(u.username, "bench%")
)

Repo.delete_all(from u in Accounts.User, where: like(u.username, "bench%"))

n = System.unique_integer([:positive])

{:ok, user} =
  %Accounts.User{}
  |> Accounts.User.registration_changeset(%{
    email: "bench#{n}@example.com",
    username: "bench#{n}",
    password: "correct horse battery staple"
  })
  |> Repo.insert()

{:ok, token, plaintext} = ApiTokens.create_for_user(user, %{name: "bench"})

{:ok, _} = Task.Supervisor.start_link(name: BenchTaskSupervisor)

# 1 = async children finished, 2 = record_use errors, 3 = token-lookup errors
counter = :counters.new(3, [:atomics])

# ------------------------------------------------------------------- arms --

reset = fn ->
  Token |> where(id: ^token.id) |> Repo.update_all(set: [last_used_at: nil])
  for i <- 1..3, do: :counters.put(counter, i, 0)
end

guarded_update = fn id ->
  now = DateTime.utc_now(:microsecond)
  cutoff = DateTime.add(now, -use_resolution, :second)

  Token
  |> where([t], t.id == ^id)
  |> where([t], is_nil(t.last_used_at) or t.last_used_at < ^cutoff)
  |> Repo.update_all(set: [last_used_at: now])
end

unconditional_update = fn id ->
  now = DateTime.utc_now(:microsecond)
  Token |> where([t], t.id == ^id) |> Repo.update_all(set: [last_used_at: now])
end

record = fn
  :none, _id ->
    :ok

  :unconditional, id ->
    unconditional_update.(id)
    :ok

  :guarded, id ->
    guarded_update.(id)
    :ok

  :async, id ->
    Task.Supervisor.start_child(BenchTaskSupervisor, fn ->
      Repo.put_dynamic_repo(:bench_repo)

      try do
        guarded_update.(id)
      rescue
        _ -> :counters.add(counter, 2, 1)
      catch
        :exit, _ -> :counters.add(counter, 2, 1)
      after
        :counters.add(counter, 1, 1)
      end
    end)

    :ok
end

# Async only counts as a win if the deferred work still lands. Block until every
# spawned child has finished before stopping the drain clock.
await_drain = fn
  :async ->
    Enum.reduce_while(1..600_000, :timeout, fn _, _ ->
      if :counters.get(counter, 1) >= total_calls,
        do: {:halt, :ok},
        else: {:cont, Process.sleep(1)}
    end)

  _ ->
    :ok
end

# ------------------------------------------------------------------- run ----

run_arm = fn arm ->
  reset.()

  parent = self()
  started = System.monotonic_time(:microsecond)

  pids =
    for _ <- 1..workers do
      spawn_monitor(fn ->
        Repo.put_dynamic_repo(:bench_repo)

        samples =
          for _ <- 1..iterations do
            # The token lookup is part of every authenticated request and shares
            # the same pool, so it stays in the workload. A pool error here is
            # counted, not raised: under saturation, dropped requests ARE the
            # phenomenon under study.
            try do
              ApiTokens.find_active_by_plaintext(plaintext)
            rescue
              _ -> :counters.add(counter, 3, 1)
            catch
              :exit, _ -> :counters.add(counter, 3, 1)
            end

            t0 = System.monotonic_time(:microsecond)

            try do
              record.(arm, token.id)
            rescue
              _ -> :counters.add(counter, 2, 1)
            catch
              :exit, _ -> :counters.add(counter, 2, 1)
            end

            System.monotonic_time(:microsecond) - t0
          end

        send(parent, {:done, self(), samples})
      end)
    end

  samples =
    Enum.flat_map(pids, fn {pid, ref} ->
      receive do
        {:done, ^pid, s} ->
          Process.demonitor(ref, [:flush])
          s

        {:DOWN, ^ref, :process, ^pid, reason} ->
          raise "worker #{inspect(pid)} died: #{inspect(reason)}"
      after
        300_000 -> raise "worker #{inspect(pid)} timed out"
      end
    end)

  caller_wall = System.monotonic_time(:microsecond) - started
  await_drain.(arm)
  drain_wall = System.monotonic_time(:microsecond) - started

  written = Repo.one(from t in Token, where: t.id == ^token.id, select: t.last_used_at)

  sorted = Enum.sort(samples)
  at = fn p -> Enum.at(sorted, min(length(sorted) - 1, trunc(length(sorted) * p))) end

  %{
    arm: arm,
    p50: at.(0.50),
    p95: at.(0.95),
    p99: at.(0.99),
    max: List.last(sorted),
    caller_wall_ms: div(caller_wall, 1000),
    drain_wall_ms: div(drain_wall, 1000),
    errors: :counters.get(counter, 2),
    lookup_errors: :counters.get(counter, 3),
    wrote?: not is_nil(written)
  }
end

arms = [:none, :unconditional, :guarded, :async]

IO.puts("""
record_use: inline vs async, hot single token
  workers=#{workers} iterations=#{iterations} calls/arm=#{total_calls} reps=#{reps}
  pool_size=#{pool_size} schedulers=#{System.schedulers_online()} @use_resolution=#{use_resolution}s

Latencies are the caller-visible cost of the record_use step alone, in
microseconds. drain = wall clock until every write has actually landed.
""")

# Interleave reps so a load spike from a sibling test suite hits every arm
# rather than poisoning one.
results =
  for rep <- 1..reps, arm <- arms do
    r = run_arm.(arm)

    IO.puts(
      "  rep #{rep} #{String.pad_trailing(to_string(r.arm), 14)} " <>
        "p50=#{r.p50}us p99=#{r.p99}us caller=#{r.caller_wall_ms}ms drain=#{r.drain_wall_ms}ms " <>
        "err=#{r.errors}/#{r.lookup_errors} wrote=#{r.wrote?}"
    )

    r
  end

median = fn list ->
  s = Enum.sort(list)
  Enum.at(s, div(length(s), 2))
end

col = fn value, width -> String.pad_leading(to_string(value), width) end

IO.puts("\n  MEDIAN OF #{reps} REPS (errors are summed, not median)\n")

IO.puts(
  String.pad_trailing("  arm", 18) <>
    col.("p50us", 9) <>
    col.("p95us", 9) <>
    col.("p99us", 9) <>
    col.("maxus", 10) <>
    col.("caller_ms", 11) <>
    col.("drain_ms", 10) <>
    col.("rec_err", 9) <>
    col.("look_err", 10)
)

for arm <- arms do
  rs = Enum.filter(results, &(&1.arm == arm))
  med = fn key -> median.(Enum.map(rs, &Map.fetch!(&1, key))) end
  sum = fn key -> Enum.sum(Enum.map(rs, &Map.fetch!(&1, key))) end

  IO.puts(
    String.pad_trailing("  #{arm}", 18) <>
      col.(med.(:p50), 9) <>
      col.(med.(:p95), 9) <>
      col.(med.(:p99), 9) <>
      col.(med.(:max), 10) <>
      col.(med.(:caller_wall_ms), 11) <>
      col.(med.(:drain_wall_ms), 10) <>
      col.(sum.(:errors), 9) <>
      col.(sum.(:lookup_errors), 10)
  )
end

Repo.delete_all(from t in Token, where: t.user_id == ^user.id)
Repo.delete_all(from u in Accounts.User, where: u.id == ^user.id)
