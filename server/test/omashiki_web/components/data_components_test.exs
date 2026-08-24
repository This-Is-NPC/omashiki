defmodule OmashikiWeb.DataComponentsTest do
  use OmashikiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OmashikiWeb.DataComponents

  describe "nil ≠ 0" do
    test "stat renders em dash for nil, never zero" do
      html = render_component(&DataComponents.stat/1, %{label: "Cached", value: nil})
      assert html =~ "—"
      refute html =~ ~r/>\s*0\s*</
    end

    test "stat keeps an explicit zero" do
      html = render_component(&DataComponents.stat/1, %{label: "Failures", value: 0})
      assert html =~ ~r/>\s*0\s*</
      refute html =~ "—"
    end

    test "data_table cell nil is em dash" do
      html =
        render_component(&DataComponents.data_table/1, %{
          cols: [%{key: :tokens, label: "Tokens"}],
          rows: [%{tokens: nil}]
        })

      assert html =~ "—"
      refute html =~ ~r/<td[^>]*>\s*0\s*</
    end
  end

  test "waffle / spark / donut / timeline emit inline SVG" do
    waffle = render_component(&DataComponents.waffle/1, %{total: 4, used: 2, cols: 4})
    spark = render_component(&DataComponents.spark/1, %{values: [1, 2, 3]})
    donut = render_component(&DataComponents.donut/1, %{value: 0.5})

    timeline =
      render_component(&DataComponents.timeline/1, %{
        from: 0,
        to: 10,
        lanes: [%{label: "a", segments: [%{from: 1, to: 4, tone: :info, label: "ok"}]}]
      })

    for html <- [waffle, spark, donut, timeline] do
      assert html =~ "<svg"
      refute html =~ "#"
      refute html =~ "apex"
    end

    assert timeline =~ "ok"
  end

  test "spark rail=12 restores run-history geometry (viewBox + h-3)" do
    html14 = render_component(&DataComponents.spark/1, %{values: [1, 2, 3], rail: 14})
    html12 = render_component(&DataComponents.spark/1, %{values: [1, 2, 3], rail: 12})

    assert html14 =~ ~s(viewBox="0 0 100 14")
    assert html14 =~ "h-3.5"
    assert html12 =~ ~s(viewBox="0 0 100 12")
    assert html12 =~ "h-3"
    refute html12 =~ "h-3.5"
  end

  test "no hardcoded hex fills in rendered markup" do
    html =
      render_component(&DataComponents.status_dot/1, %{tone: :success, label: "ok"}) <>
        render_component(&DataComponents.waffle/1, %{total: 4, used: 2, cols: 4})

    refute html =~ ~r/#[0-9a-fA-F]{3,8}/
  end

  describe "Etapa 6 absorption — tone helpers" do
    test "tone_class matches status token vocabulary" do
      assert DataComponents.tone_class(:success) == "text-status-success"
      assert DataComponents.tone_class(:failed) == "text-status-failed"
      assert DataComponents.tone_class(:warning) == "text-status-awaiting"
      assert DataComponents.tone_class(:info) == "text-status-running"
      assert DataComponents.tone_class(:neutral) == "text-on-surface"
    end

    test "status_tone covers every status_color branch" do
      assert DataComponents.status_tone("completed") == :success
      assert DataComponents.status_tone("succeeded") == :success
      assert DataComponents.status_tone("ok") == :success
      assert DataComponents.status_tone("closed") == :success
      assert DataComponents.status_tone("failure") == :failed
      assert DataComponents.status_tone("error") == :failed
      assert DataComponents.status_tone("canceled") == :cancelled
      assert DataComponents.status_tone("aborted") == :cancelled
      assert DataComponents.status_tone("retired") == :cancelled
      assert DataComponents.status_tone("awaiting_commit") == :warning
      assert DataComponents.status_tone("pending") == :warning
      assert DataComponents.status_tone("open") == :failed
      assert DataComponents.status_tone("half_open") == :warning
      assert DataComponents.status_tone("in_progress") == :info
      assert DataComponents.status_tone("active") == :info
      assert DataComponents.status_tone("standby") == :info
      assert DataComponents.status_tone("mystery") == :cancelled
    end

    test "status_dot resolves status labels without tone" do
      html = render_component(&DataComponents.status_dot/1, %{status: "completed"})
      assert html =~ "bg-status-success"
      assert html =~ "completed"
    end

    test "stat typography matches kpi content classes" do
      html =
        render_component(&DataComponents.stat/1, %{
          label: "Success",
          value: "94%",
          tone: :success
        })

      assert html =~ "font-label"
      assert html =~ "tracking-[0.3em]"
      assert html =~ "text-2xl"
      # cq stays off the root (flex-item collapse); value still opts into cq-md-*
      refute standalone_cq?(html)
      assert html =~ "cq-md-text-3xl"
      assert html =~ "text-status-success"
      # content only — no card chrome
      refute html =~ "border-outline-variant"
      refute html =~ "px-6"
      refute html =~ "md:text-3xl"
    end

    test "kv_row uses container query columns, not viewport" do
      html =
        render_component(&DataComponents.kv_row/1, %{
          label: "max_parallel",
          value: 4,
          source: "project"
        })

      assert html =~ ~r/\bcq\b/
      assert html =~ "cq-md-grid-cols-kv"
      assert html =~ "cq-sm-grid-cols-kv-2"
      refute html =~ "md:grid-cols"
      # container-type and @container utilities must not share a node
      refute cq_same_node?(html)
    end

    test "stat keeps cq off the root so cq-md-* is descendant-only" do
      html =
        render_component(&DataComponents.stat/1, %{
          label: "Success",
          value: "94%",
          tone: :success
        })

      refute cq_same_node?(html)
      refute standalone_cq?(html)
      assert html =~ "cq-md-text-3xl"
    end
  end

  describe "fetch states" do
    test "stat loading shows Loading… never the figure or em dash" do
      html =
        render_component(&DataComponents.stat/1, %{
          label: "Runs",
          value: 128,
          state: :loading
        })

      assert html =~ "Loading…"
      assert html =~ ~s|aria-busy="true"|
      refute html =~ "128"
      refute html =~ "—"
    end

    test "stat error shows failure copy, not the figure" do
      html =
        render_component(&DataComponents.stat/1, %{
          label: "Runs",
          value: 128,
          state: :error,
          error: "Metrics gateway unreachable"
        })

      assert html =~ "Metrics gateway unreachable"
      assert html =~ ~s|role="alert"|
      refute html =~ "128"
    end

    test "data_table loading is not the empty dash" do
      html =
        render_component(&DataComponents.data_table/1, %{
          state: :loading,
          cols: [%{key: :a, label: "A"}],
          rows: []
        })

      assert html =~ "Loading…"
      refute html =~ "<table"
      refute html =~ "—"
    end
  end

  describe "accessibility" do
    test "waffle is a progressbar announcing used/total" do
      html = render_component(&DataComponents.waffle/1, %{total: 16, used: 8, cols: 8})
      assert html =~ ~s|role="progressbar"|
      assert html =~ ~s|aria-valuemin="0"|
      assert html =~ ~s|aria-valuemax="16"|
      assert html =~ ~s|aria-valuenow="8"|
      assert html =~ ~s|aria-label="8 of 16 used"|
      refute html =~ ~s|aria-label="waffle"|
    end

    test "gauge wrapper is progressbar; track SVG is decorative" do
      html =
        render_component(&DataComponents.gauge/1, %{
          label: "Host slots",
          used: 7,
          total: 16,
          unit: "slots"
        })

      assert html =~ ~s|role="progressbar"|
      assert html =~ ~s|aria-valuenow="7"|
      assert html =~ ~s|aria-valuemax="16"|
      assert html =~ ~s|aria-label="Host slots: 7 of 16 slots"|
      assert html =~ ~s|aria-hidden="true"|
      refute html =~ ~s|aria-label="gauge"|
    end

    test "donut progressbar announces percentage data, never chart type" do
      html =
        render_component(&DataComponents.donut/1, %{
          value: 0.86,
          label: "Audit score",
          tone: :success
        })

      assert html =~ ~s|role="progressbar"|
      assert html =~ ~s|aria-valuenow="86"|
      assert html =~ ~s|aria-valuemin="0"|
      assert html =~ ~s|aria-valuemax="100"|
      assert html =~ ~s|aria-label="Audit score: 86%"|
      refute html =~ ~s|aria-label="donut"|
    end

    test "spark defaults to decorative; label makes it named" do
      bare = render_component(&DataComponents.spark/1, %{values: [1, 2, 3]})
      assert bare =~ "aria-hidden"
      refute bare =~ ~s|aria-label="sparkline"|

      named =
        render_component(&DataComponents.spark/1, %{
          values: [1, 2, 3],
          label: "CPU last hour"
        })

      assert named =~ ~s|aria-label="CPU last hour"|
      refute named =~ "aria-hidden"
    end

    test "data_table column headers carry scope=col" do
      html =
        render_component(&DataComponents.data_table/1, %{
          cols: [%{key: :name, label: "Name"}],
          rows: [%{name: "a"}]
        })

      assert html =~ ~s|scope="col"|
    end

    test "progress requires an accessible name" do
      html =
        render_component(&DataComponents.progress/1, %{
          label: "Upload",
          value: 0.42,
          tone: :primary
        })

      assert html =~ ~s|role="progressbar"|
      assert html =~ ~s|aria-label="Upload"|
      assert html =~ ~s|aria-valuenow="42"|
    end

    test "timeline and bar_group aria-labels come from data" do
      timeline =
        render_component(&DataComponents.timeline/1, %{
          from: 0,
          to: 10,
          lanes: [%{label: "builder", segments: [%{from: 1, to: 4, tone: :info}]}]
        })

      assert timeline =~ ~s|aria-label="builder, 0 to 10"|
      refute timeline =~ ~s|aria-label="timeline"|

      bars =
        render_component(&DataComponents.bar_group/1, %{
          labels: ["input", "output"],
          series: [1, 2]
        })

      assert bars =~ ~s|aria-label="input, output"|
      refute bars =~ ~s|aria-label="bar group"|
    end

    test "timeline paints when from == to (instant event log)" do
      t = ~U[2024-01-01 12:00:00Z]

      html =
        render_component(&DataComponents.timeline/1, %{
          from: t,
          to: t,
          lanes: [
            %{
              label: "container.provisioned",
              segments: [%{from: t, to: t, tone: :primary, label: "ok"}]
            }
          ]
        })

      assert html =~ "<svg"
      assert html =~ "container.provisi"
      assert html =~ "<title>container.provisioned</title>"
      assert html =~ "ok"
    end
  end

  # container-type (`cq`) and @container utilities (`cq-sm-*` / `cq-md-*`)
  # must never share a class attribute — queries only match descendants.
  defp cq_same_node?(html) do
    html
    |> then(&Regex.scan(~r/class="([^"]*)"/, &1))
    |> Enum.any?(fn [_, class] ->
      Regex.match?(~r/(^|\s)cq(\s|$)/, class) and
        Regex.match?(~r/(^|\s)cq-(sm|md)-/, class)
    end)
  end

  # Standalone `cq` utility (not `cq-md-*` / `cq-sm-*`).
  defp standalone_cq?(html) do
    html
    |> then(&Regex.scan(~r/class="([^"]*)"/, &1))
    |> Enum.any?(fn [_, class] ->
      Regex.match?(~r/(^|\s)cq(\s|$)/, class)
    end)
  end
end
