defmodule Omashiki.FleetTest do
  use ExUnit.Case, async: false

  alias Omashiki.Fleet
  alias Omashiki.Worker.{Poller, Presence}

  @attempt_id "7d3f7c2e-9d1a-4c55-9a51-2f7e2b3c4d5e"

  setup do
    Presence.reset()
    on_exit(fn -> Presence.reset() end)
  end

  describe "parse_containers/1" do
    test "keeps only the validated fields of a report" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      container = %{
        id: "a1b2c3d4e5f60718",
        scope_id: "job-" <> @attempt_id,
        attempt_id: @attempt_id,
        state: "running",
        created_at: now,
        started_at: now
      }

      wire = container |> Fleet.encode_container() |> Map.put("env", "SECRET=1")

      assert {:ok, [^container]} = Fleet.parse_containers([wire])
      assert {:ok, []} = Fleet.parse_containers(nil)
    end

    test "rejects anything that is not a plain container report" do
      valid = %{"id" => "a1b2c3d4e5f60718", "state" => "running"}

      for bad <- [
            %{valid | "id" => "../../etc"},
            %{valid | "state" => "exploded"},
            Map.put(valid, "attempt_id", "not-a-uuid"),
            Map.put(valid, "created_at", "yesterday"),
            "a1b2c3d4e5f60718"
          ] do
        assert {:error, :invalid_containers} = Fleet.parse_containers([bad])
      end

      assert {:error, :invalid_containers} = Fleet.parse_containers(List.duplicate(valid, 201))
      assert {:error, :invalid_containers} = Fleet.parse_containers(%{"id" => "x"})
    end
  end

  describe "presence reports" do
    test "a report is recorded with the worker and survives a later poll" do
      container = %{id: "a1b2c3d4e5f60718", attempt_id: @attempt_id, state: "running"}

      :ok = Presence.report("vps-1", %{free_slots: 1, capacity: 4, containers: [container]})
      :ok = Presence.touch("vps-1", %{free_slots: 1})

      assert %{kind: :worker, capacity: 4, free_slots: 1, containers: [^container]} =
               Enum.find(Fleet.nodes(), &(&1.machine_id == "vps-1"))
    end

    test "only a change is announced" do
      Fleet.subscribe()
      report = %{free_slots: 2, capacity: 4, containers: []}

      :ok = Presence.report("vps-2", report)
      assert_receive {:fleet_updated, "vps-2"}

      :ok = Presence.report("vps-2", report)
      refute_receive {:fleet_updated, "vps-2"}, 50

      :ok = Presence.report("vps-2", %{report | free_slots: 1})
      assert_receive {:fleet_updated, "vps-2"}
    end
  end

  describe "worker report scope" do
    test "a house sees only the containers of its own in-flight attempts" do
      other_attempt = "11111111-2222-4333-8444-555555555555"

      containers = [
        %{id: "aaaaaaaaaaaa", attempt_id: @attempt_id},
        %{id: "bbbbbbbbbbbb", attempt_id: other_attempt},
        %{id: "cccccccccccc", attempt_id: nil}
      ]

      in_flight = %{
        @attempt_id => %{offer: %{manager_id: "ana"}},
        other_attempt => %{offer: %{manager_id: "joao"}}
      }

      assert [%{id: "aaaaaaaaaaaa"}] = Poller.containers_for_manager(containers, in_flight, "ana")

      assert [%{id: "bbbbbbbbbbbb"}] =
               Poller.containers_for_manager(containers, in_flight, "joao")

      assert [] = Poller.containers_for_manager(containers, in_flight, "nobody")
    end

    test "the client sends the report to the manager" do
      bypass = Bypass.open()
      parent = self()

      Bypass.expect_once(bypass, "POST", "/internal/work/report", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        send(
          parent,
          {:report, Plug.Conn.get_req_header(conn, "authorization"), Jason.decode!(body)}
        )

        Plug.Conn.resp(conn, 204, "")
      end)

      client = Omashiki.Worker.Client.new("http://127.0.0.1:#{bypass.port}", "worker-token")

      container = %{
        id: "aaaaaaaaaaaa",
        attempt_id: @attempt_id,
        state: "created",
        created_at: nil,
        started_at: nil
      }

      assert :ok = Omashiki.Worker.Client.report(client, "vps-1", 3, 4, [container])

      assert_receive {:report, ["Bearer worker-token"], body}
      assert %{"machine_id" => "vps-1", "free_slots" => 3, "capacity" => 4} = body

      assert [%{"id" => "aaaaaaaaaaaa", "attempt_id" => @attempt_id, "state" => "created"}] =
               body["containers"]
    end
  end
end
