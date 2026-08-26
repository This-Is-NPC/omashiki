defmodule Omashiki.Runtime.InspectorTest do
  @moduledoc """
  The join is the point.

  Processes come from the attempt registry, containers from the runtime port,
  and attempt rows from PostgreSQL. Each source on its own looks healthy in
  exactly the failure this exists to catch: during a seventeen-minute wedge the
  capacity table said nothing was reserved, no attempt was active, and the model
  server was idle — every individual reading was fine and the system was stuck.
  What no single source could say was that the three disagreed.
  """

  use Omashiki.DataCase, async: true

  alias Omashiki.Runtime.Inspector

  @node "howlscastle"

  describe "correlate/4" do
    test "a process holding a container is linked" do
      attempt = attempt("a")

      [row] = Inspector.correlate([container("c1", "job-a")], [attempt], [{"a", self()}], @node)

      assert row.link == :linked
      assert row.attempt_id == "a"
      assert row.pid == self()
      assert [%{id: "c1"}] = row.containers
    end

    # The state that took application boot down with 84 of them during a load
    # test. Nothing owns the container, so nothing will ever destroy it.
    test "a container whose attempt has no process is an orphaned container" do
      [row] = Inspector.correlate([container("c1", "job-a")], [], [], @node)

      assert row.link == :orphan_container
      assert row.attempt_id == "a"
      assert row.pid == nil
      assert [%{id: "c1"}] = row.containers
    end

    test "a container carrying no scope label at all is an orphaned container" do
      [row] = Inspector.correlate([container("c1", nil)], [], [], @node)

      assert row.link == :orphan_container
      assert row.attempt_id == nil
    end

    test "two unlabelled containers stay two rows rather than collapsing into one" do
      rows = Inspector.correlate([container("c1", nil), container("c2", nil)], [], [], @node)

      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.link == :orphan_container))

      assert Enum.map(rows, & &1.containers) |> List.flatten() |> Enum.map(& &1.id) == [
               "c1",
               "c2"
             ]
    end

    # The other half of the pair, and it must not read as the same fault: this
    # one has an owner, so something will clean up after it.
    test "a process with no container is not an orphaned container" do
      attempt = attempt("a", status: "provisioning")

      [row] = Inspector.correlate([], [attempt], [{"a", self()}], @node)

      assert row.link == :process_without_container
      assert row.pid == self()
      assert row.containers == []
    end

    test "a process with no attempt row is still a process without a container" do
      [row] = Inspector.correlate([], [], [{"a", self()}], @node)

      assert row.link == :process_without_container
      assert row.status == nil
    end

    # The wedge signature: the database says an attempt is running on this node
    # and this node has neither a coordinator nor a container for it.
    test "an active attempt on this node with neither process nor container is stranded" do
      [row] = Inspector.correlate([], [attempt("a")], [], @node)

      assert row.link == :attempt_without_process
      assert row.node_id == @node
    end

    # Without this the console on a two-node install would report every attempt
    # running on the other machine as stranded, which is the fastest way to make
    # an operator stop believing the screen.
    test "an attempt owned by another node is not stranded, it is remote" do
      [row] = Inspector.correlate([], [attempt("a", node_id: "other-host")], [], @node)

      assert row.link == :remote
      assert row.node_id == "other-host"
    end

    test "the two orphan states sort ahead of the healthy ones" do
      rows =
        Inspector.correlate(
          [container("c1", "job-linked"), container("c2", "job-orphan")],
          [attempt("linked"), attempt("stranded")],
          [{"linked", self()}, {"lonely", self()}],
          @node
        )

      assert Enum.map(rows, & &1.link) == [
               :orphan_container,
               :process_without_container,
               :attempt_without_process,
               :linked
             ]
    end

    test "counts/1 tallies one entry per link state" do
      rows =
        Inspector.correlate(
          [container("c1", "job-linked"), container("c2", "job-orphan")],
          [attempt("linked")],
          [{"linked", self()}],
          @node
        )

      assert Inspector.counts(rows) == %{
               linked: 1,
               orphan_container: 1,
               process_without_container: 0,
               attempt_without_process: 0,
               remote: 0
             }
    end
  end

  describe "the census is polled, never rendered" do
    setup do
      calls = :counters.new(1, [])

      {:ok, pid} =
        Inspector.start_link(
          name: nil,
          interval_ms: 25,
          census: {__MODULE__, :counting_census, [calls]}
        )

      {:ok, inspector: pid, calls: calls}
    end

    # A render that reaches for the runtime port is a render that makes an HTTP
    # request to the Docker daemon. Under load, with several operators watching,
    # the observability screen would become a cause of the outage it exists to
    # explain.
    test "reading the snapshot never touches the runtime port", ctx do
      Inspector.refresh(ctx.inspector)
      assert :counters.get(ctx.calls, 1) == 1

      for _ <- 1..20, do: Inspector.snapshot(ctx.inspector)

      assert :counters.get(ctx.calls, 1) == 1
    end

    # Polling on a timer regardless of demand would mean the cost of this page
    # is paid forever after the first person opens it once.
    test "an unwatched inspector does not poll at all", ctx do
      Process.sleep(150)

      assert :counters.get(ctx.calls, 1) == 0
    end

    test "a watcher makes it poll, and dropping the watcher stops it", ctx do
      watcher = spawn(fn -> Process.sleep(:infinity) end)
      Inspector.watch(ctx.inspector, watcher)

      Process.sleep(150)
      polled = :counters.get(ctx.calls, 1)
      assert polled > 0

      Process.exit(watcher, :kill)
      Process.sleep(60)
      settled = :counters.get(ctx.calls, 1)

      Process.sleep(150)
      assert :counters.get(ctx.calls, 1) == settled
    end

    test "a runtime port that is down is reported, not rendered as an empty host", ctx do
      {:ok, pid} =
        Inspector.start_link(
          name: nil,
          interval_ms: 60_000,
          census: {__MODULE__, :unavailable_census, []}
        )

      snapshot = Inspector.refresh(pid)

      assert snapshot.runtime == {:error, :docker_unavailable}
      assert snapshot.rows == []
      refute is_nil(ctx.inspector)
    end
  end

  # The digest was captured on every job at admission and, before this, never
  # read back. These pin the read: which generation a running container is on,
  # and what fraction of the fleet has crossed over.
  describe "configuration generations" do
    @live String.duplicate("1", 64)
    @old String.duplicate("2", 64)

    test "an attempt admitted under the live digest is on the live generation" do
      [row] =
        Inspector.correlate(
          [container("c1", "job-a")],
          [attempt("a", registry_digest: @live)],
          [{"a", self()}],
          @node,
          @live
        )

      assert row.generation == :current
    end

    # Not "stale" — it is correctly finishing on what admitted it. This is the
    # state a gradual rollout spends its whole life in.
    test "an attempt admitted under a superseded digest is on the prior generation" do
      [row] =
        Inspector.correlate(
          [container("c1", "job-a")],
          [attempt("a", registry_digest: @old)],
          [{"a", self()}],
          @node,
          @live
        )

      assert row.generation == :prior
      assert row.registry_digest == @old
    end

    test "a container nothing claims has no generation to be on" do
      [row] = Inspector.correlate([container("c1", nil)], [], [], @node, @live)

      assert row.generation == :unknown
    end

    test "the applied percentage is attempts on the live digest over all of them" do
      rows =
        Inspector.correlate(
          [],
          [
            attempt("a", registry_digest: @live),
            attempt("b", registry_digest: @live),
            attempt("c", registry_digest: @live),
            attempt("d", registry_digest: @old)
          ],
          [],
          @node,
          @live
        )

      assert %{applied_percent: 75, current: 3, prior: 1, total: 4} =
               Inspector.config_state(rows, @live)
    end

    # An idle host has nothing left running against a superseded generation, so
    # the rollout is done. Reporting 0% there would show a permanent stall on a
    # system with nothing wrong with it.
    test "an idle host is fully applied, not zero percent applied" do
      assert %{applied_percent: 100, total: 0} = Inspector.config_state([], @live)
    end

    test "an orphan container does not dilute the percentage" do
      rows =
        Inspector.correlate(
          [container("c1", nil), container("c2", nil)],
          [attempt("a", registry_digest: @live)],
          [],
          @node,
          @live
        )

      assert %{applied_percent: 100, total: 1} = Inspector.config_state(rows, @live)
    end

    # The tests above hand `correlate/5` an attempt map they built themselves,
    # so they would stay green even if the production query never selected the
    # digest at all. This one goes through `build/1`, which reads real rows —
    # `registry_digest` lives on `jobs`, not on `job_attempts`, so the join is
    # the thing being pinned.
    test "the census reads the admitted digest off the job row" do
      user = Omashiki.Fixtures.user_fixture()
      {token, _plaintext} = Omashiki.Fixtures.api_token_fixture(user)

      {_job, attempt} =
        Omashiki.JobFixtures.job_fixture(user, token, %{
          status: "running",
          registry_digest: @old
        })

      snapshot = Inspector.build({__MODULE__, :no_census, []})
      row = Enum.find(snapshot.rows, &(&1.attempt_id == attempt.id))

      refute is_nil(row), "the running attempt should appear in the census"
      assert row.registry_digest == @old
      assert row.generation == :prior
      assert snapshot.config.prior == 1
      assert snapshot.config.applied_percent == 0
    end

    test "a full census carries the configuration state" do
      {:ok, pid} =
        Inspector.start_link(name: nil, interval_ms: 60_000, census: {__MODULE__, :no_census, []})

      snapshot = Inspector.refresh(pid)

      assert %{applied_percent: 100, digest: digest} = snapshot.config
      assert digest == Omashiki.Config.current_digest()
      assert snapshot.config.generation == Omashiki.Config.generation()
    end
  end

  @doc false
  def no_census, do: {:ok, []}

  @doc false
  def counting_census(calls) do
    :counters.add(calls, 1, 1)
    {:ok, []}
  end

  @doc false
  def unavailable_census, do: {:error, :docker_unavailable}

  defp container(id, scope_id) do
    %{id: id, scope_id: scope_id, state: "running", status: "Up 2 minutes", created_at: nil}
  end

  defp attempt(id, opts \\ []) do
    %{
      id: id,
      job_id: "job-row-#{id}",
      status: Keyword.get(opts, :status, "running"),
      node_id: Keyword.get(opts, :node_id, @node),
      started_at: Keyword.get(opts, :started_at),
      registry_digest: Keyword.get(opts, :registry_digest)
    }
  end
end
