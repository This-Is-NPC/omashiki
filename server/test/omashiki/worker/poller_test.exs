defmodule Omashiki.Worker.PollerTest do
  use ExUnit.Case, async: false

  alias Omashiki.Worker.{Complete, Offer, Poller, Slots}

  @poll_interval_ms 60_000

  setup do
    on_exit(fn ->
      restore_env(:manager_url)
      restore_env(:worker_token)
      restore_env(:worker_executor)
      restore_env(:worker_poll_interval_ms)
      restore_env(:fake_executor_result)
      restore_env(:fake_executor_owner)
      restore_env(:fake_executor_mode)
      restore_env(:worker_managers)
    end)

    :ok
  end

  describe "idle boot" do
    test "stays alive without manager_url, worker_token, or executor and sends no HTTP traffic" do
      parent = self()
      bypass = Bypass.open()

      for {method, path} <- [
            {"POST", "/internal/work/register"},
            {"POST", "/internal/work/poll"},
            {"POST", "/internal/work/complete"}
          ] do
        Bypass.stub(bypass, method, path, fn conn ->
          send(parent, {:http_hit, path})
          Plug.Conn.resp(conn, 500, "")
        end)
      end

      Application.delete_env(:omashiki, :manager_url)
      Application.delete_env(:omashiki, :worker_token)
      Application.delete_env(:omashiki, :worker_executor)

      assert {:ok, pid} = start_supervised({Poller, name: unique_poller_name()})
      assert Process.alive?(pid)

      Process.sleep(50)
      refute_receive {:http_hit, _}, 50
    end
  end

  describe "executor round-trip" do
    setup do
      bypass = Bypass.open()
      parent = self()
      token = "worker-poller-#{System.unique_integer([:positive])}"
      put_env(:manager_url, "http://127.0.0.1:#{bypass.port}")
      put_env(:worker_token, token)
      put_env(:worker_executor, Omashiki.Worker.PollerTest.FakeExecutor)
      put_env(:worker_poll_interval_ms, @poll_interval_ms)
      put_env(:fake_executor_owner, parent)

      stub_heartbeat(bypass)

      slots = start_slots!()

      {:ok, bypass: bypass, token: token, parent: parent, slots: slots}
    end

    test "completes a git sink offer", %{bypass: bypass, parent: parent, slots: slots} do
      offer = sample_offer("git")

      expect_register(bypass)
      expect_accept(bypass, parent)
      expect_poll_sequence(bypass, [offer], parent)

      expect_complete(bypass, parent, fn body ->
        assert body["complete"]["kind"] == "git"
        assert body["complete"]["remote"] == "https://example.com/repo.git"
        assert body["complete"]["branch"] == "main"
        assert body["complete"]["base_sha"] == "abc"
        assert body["complete"]["head_sha"] == "def"
      end)

      put_env(:fake_executor_result, {
        :ok,
        %Complete{
          kind: :git,
          remote: "https://example.com/repo.git",
          branch: "main",
          base_sha: "abc",
          head_sha: "def"
        }
      })

      assert {:ok, _pid} = start_poller(slots)
      assert_receive {:accept, _}, 2_000
      assert_receive {:complete, _}, 2_000
    end

    test "uploads a blob then completes a files sink offer", %{
      bypass: bypass,
      parent: parent,
      slots: slots
    } do
      offer = sample_offer("files")

      blob_path =
        Path.join(System.tmp_dir!(), "poller-blob-#{System.unique_integer([:positive])}")

      blob = "artifact-bytes"
      digest = :crypto.hash(:sha256, blob) |> Base.encode16(case: :lower)
      File.write!(blob_path, blob)

      on_exit(fn -> File.rm(blob_path) end)

      expect_register(bypass)
      expect_accept(bypass, parent)
      expect_poll_sequence(bypass, [offer], parent)

      Bypass.expect(bypass, "PUT", "/internal/work/blobs/#{offer["job_id"]}", fn conn ->
        assert {"x-omashiki-digest", ^digest} =
                 List.keyfind(conn.req_headers, "x-omashiki-digest", 0)

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:blob, body})
        Plug.Conn.resp(conn, 201, ~s({"path":"/tmp/blob","digest":"#{digest}"}))
      end)

      expect_complete(bypass, parent, fn body ->
        assert body["complete"]["kind"] == "files"
        assert body["complete"]["blob_digest"] == digest
        assert body["complete"]["changed_bytes"] == byte_size(blob)
        refute Map.has_key?(body["complete"], "blob_path")
      end)

      put_env(:fake_executor_result, {
        :ok,
        %Complete{
          kind: :files,
          changed_bytes: byte_size(blob),
          blob_digest: digest,
          blob_path: blob_path
        }
      })

      assert {:ok, _pid} = start_poller(slots)
      assert_receive {:accept, _}, 2_000
      assert_receive {:blob, ^blob}, 2_000
      assert_receive {:complete, _}, 2_000
    end

    test "completes a none sink offer", %{bypass: bypass, parent: parent, slots: slots} do
      offer = sample_offer("none")

      expect_register(bypass)
      expect_accept(bypass, parent)
      expect_poll_sequence(bypass, [offer], parent)

      expect_complete(bypass, parent, fn body ->
        assert body["complete"] == %{"kind" => "none", "changed_bytes" => 0}
      end)

      put_env(:fake_executor_result, {:ok, %Complete{kind: :none, changed_bytes: 0}})

      assert {:ok, _pid} = start_poller(slots)
      assert_receive {:accept, _}, 2_000
      assert_receive {:complete, _}, 2_000
    end

    test "posts an error complete when the executor fails", %{
      bypass: bypass,
      parent: parent,
      slots: slots
    } do
      offer = sample_offer("git")

      expect_register(bypass)
      expect_accept(bypass, parent)
      expect_poll_sequence(bypass, [offer], parent)

      expect_complete(bypass, parent, fn body ->
        assert body["complete"]["kind"] == "error"
        assert body["complete"]["code"] == "executor_failed"
        assert is_binary(body["complete"]["message"])
      end)

      put_env(:fake_executor_result, {:error, :boom})

      assert {:ok, _pid} = start_poller(slots)
      assert_receive {:accept, _}, 2_000
      assert_receive {:complete, _}, 2_000
    end
  end

  describe "slot limits" do
    setup do
      bypass = Bypass.open()
      parent = self()
      token = "worker-poller-#{System.unique_integer([:positive])}"
      put_env(:manager_url, "http://127.0.0.1:#{bypass.port}")
      put_env(:worker_token, token)
      put_env(:worker_executor, Omashiki.Worker.PollerTest.FakeExecutor)
      put_env(:worker_poll_interval_ms, @poll_interval_ms)
      put_env(:fake_executor_owner, parent)
      put_env(:fake_executor_mode, :hang)
      put_env(:fake_executor_result, {:ok, %Complete{kind: :none, changed_bytes: 0}})

      stub_heartbeat(bypass)

      {:ok, bypass: bypass, parent: parent}
    end

    test "does not run a second executor while max=1 slot is held", %{
      bypass: bypass,
      parent: parent
    } do
      slots = start_slots!(1)
      offer1 = sample_offer("none")
      offer2 = sample_offer("none")

      expect_register(bypass, 1)
      expect_accept(bypass, parent)
      expect_poll_sequence(bypass, [offer1, offer2], parent)
      expect_complete(bypass, parent, fn _ -> :ok end)

      assert {:ok, _pid} = start_poller(slots)

      assert_receive {:accept, _}, 2_000
      assert_receive {:run, _offer, executor_pid}, 2_000
      refute_receive {:complete, _}, 200
      refute_receive {:accept, _}, 500
      refute_receive {:run, _, _}, 500

      send(executor_pid, :release_executor)
      assert_receive {:complete, _}, 2_000
    end

    test "registers with zero free slots when the pool is pre-acquired", %{
      bypass: bypass
    } do
      slots = start_slots!(1)
      assert :ok = Slots.try_acquire(slots)
      assert Slots.available(slots) == 0

      expect_register(bypass, 0)

      assert {:ok, _pid} = start_poller(slots)
      refute_receive {:poll, _}, 200

      Slots.release(slots)
    end

    test "accepts two concurrent jobs when max=2 and rejects a third", %{
      bypass: bypass,
      parent: parent
    } do
      slots = start_slots!(2)
      offer1 = sample_offer("none")
      offer2 = sample_offer("none")
      offer3 = sample_offer("none")

      expect_register(bypass, 2)
      expect_accept(bypass, parent)
      expect_poll_sequence(bypass, [offer1, offer2, offer3], parent)
      expect_complete(bypass, parent, fn _ -> :ok end)

      assert {:ok, _pid} = start_poller(slots)

      assert_receive {:accept, _}, 2_000
      assert_receive {:run, _, executor1}, 2_000
      assert_receive {:accept, _}, 2_000
      assert_receive {:run, _, executor2}, 2_000

      refute_receive {:complete, _}, 200
      refute_receive {:accept, _}, 500
      refute_receive {:run, _, _}, 500

      send(executor1, :release_executor)
      send(executor2, :release_executor)
      assert_receive {:complete, _}, 2_000
      assert_receive {:complete, _}, 2_000
    end
  end

  describe "multi-manager round-robin" do
    setup do
      bypass_a = Bypass.open()
      bypass_b = Bypass.open()
      parent = self()

      Application.delete_env(:omashiki, :manager_url)
      Application.delete_env(:omashiki, :worker_token)
      put_env(:worker_executor, Omashiki.Worker.PollerTest.FakeExecutor)
      put_env(:worker_poll_interval_ms, @poll_interval_ms)
      put_env(:fake_executor_owner, parent)
      put_env(:fake_executor_mode, :hang)
      put_env(:fake_executor_result, {:ok, %Complete{kind: :none, changed_bytes: 0}})

      managers = [
        %{id: "mgr-a", url: "http://127.0.0.1:#{bypass_a.port}", token: "token-a"},
        %{id: "mgr-b", url: "http://127.0.0.1:#{bypass_b.port}", token: "token-b"}
      ]

      stub_heartbeat(bypass_a)
      stub_heartbeat(bypass_b)

      slots = start_slots!(2)

      {:ok,
       bypass_a: bypass_a, bypass_b: bypass_b, parent: parent, managers: managers, slots: slots}
    end

    test "polls two managers and completes to the originating bypass", %{
      bypass_a: bypass_a,
      bypass_b: bypass_b,
      parent: parent,
      managers: managers,
      slots: slots
    } do
      offer_a = sample_offer("none")
      offer_b = sample_offer("none")

      expect_register(bypass_a)
      expect_register(bypass_b)
      expect_accept(bypass_a, parent)
      expect_accept(bypass_b, parent)
      expect_poll_sequence(bypass_a, [offer_a], parent)
      expect_poll_sequence(bypass_b, [offer_b], parent)

      expect_complete(bypass_a, parent, fn _ -> send(parent, {:complete_from, :a}) end)
      expect_complete(bypass_b, parent, fn _ -> send(parent, {:complete_from, :b}) end)

      assert {:ok, poller} =
               start_supervised(
                 {Poller, name: unique_poller_name(), slots: slots, managers: managers}
               )

      assert_receive {:accept, %{"attempt_id" => attempt_a}}, 2_000
      assert_receive {:run, %Offer{attempt_id: ^attempt_a, manager_id: "mgr-a"}, pid_a}, 2_000

      send(poller, :tick)

      assert_receive {:accept, %{"attempt_id" => attempt_b}}, 2_000
      assert_receive {:run, %Offer{attempt_id: ^attempt_b, manager_id: "mgr-b"}, pid_b}, 2_000

      send(pid_a, :release_executor)
      assert_receive {:complete_from, :a}, 2_000
      refute_receive {:complete_from, :b}, 200

      send(pid_b, :release_executor)
      assert_receive {:complete_from, :b}, 2_000
    end

    test "uploads files blob to the originating manager only", %{
      bypass_a: bypass_a,
      bypass_b: bypass_b,
      parent: parent,
      managers: managers,
      slots: slots
    } do
      offer_a = sample_offer("files")

      blob_path =
        Path.join(System.tmp_dir!(), "poller-blob-#{System.unique_integer([:positive])}")

      blob = "artifact-bytes"
      digest = :crypto.hash(:sha256, blob) |> Base.encode16(case: :lower)
      File.write!(blob_path, blob)

      on_exit(fn -> File.rm(blob_path) end)

      expect_register(bypass_a)
      expect_register(bypass_b)
      expect_accept(bypass_a, parent)
      expect_poll_sequence(bypass_a, [offer_a], parent)
      expect_poll_sequence(bypass_b, [], parent)

      Bypass.expect(bypass_a, "PUT", "/internal/work/blobs/#{offer_a["job_id"]}", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:blob, body})
        Plug.Conn.resp(conn, 201, ~s({"path":"/tmp/blob","digest":"#{digest}"}))
      end)

      Bypass.stub(bypass_b, "PUT", "/internal/work/blobs/#{offer_a["job_id"]}", fn conn ->
        send(parent, {:blob_wrong_manager, true})
        Plug.Conn.resp(conn, 500, "")
      end)

      expect_complete(bypass_a, parent, fn body ->
        assert body["complete"]["kind"] == "files"
        assert body["complete"]["blob_digest"] == digest
      end)

      put_env(:fake_executor_mode, nil)

      put_env(:fake_executor_result, {
        :ok,
        %Complete{
          kind: :files,
          changed_bytes: byte_size(blob),
          blob_digest: digest,
          blob_path: blob_path
        }
      })

      assert {:ok, _pid} =
               start_supervised(
                 {Poller, name: unique_poller_name(), slots: slots, managers: managers}
               )

      assert_receive {:accept, _}, 2_000
      assert_receive {:blob, ^blob}, 2_000
      assert_receive {:complete, _}, 2_000
      refute_receive {:blob_wrong_manager, _}, 200
    end
  end

  defmodule FakeExecutor do
    @behaviour Omashiki.Worker.Executor

    alias Omashiki.Worker.Offer

    @impl Omashiki.Worker.Executor
    def run(%Offer{} = offer) do
      owner = Application.get_env(:omashiki, :fake_executor_owner)

      if owner do
        send(owner, {:run, offer, self()})
      end

      case Application.get_env(:omashiki, :fake_executor_mode) do
        :hang ->
          receive do
            :release_executor ->
              Application.get_env(:omashiki, :fake_executor_result)
          end

        _ ->
          Application.get_env(:omashiki, :fake_executor_result)
      end
    end
  end

  defp sample_offer(sink) do
    n = System.unique_integer([:positive])

    %{
      "job_id" => "job_#{n}",
      "attempt_id" => "attempt_#{n}",
      "lease_token" => "lease_#{n}",
      "sink" => sink,
      "payload" => %{"instruction" => "do work"},
      "admitted_environment" => %{"sink" => sink},
      "admitted_repository" => nil,
      "admitted_plugin" => nil,
      "registry_digest" => nil,
      "timeout_ms" => 60_000
    }
  end

  defp start_slots!(max \\ 2) do
    name = :"Omashiki.Worker.Slots.Test.#{System.unique_integer([:positive])}"
    {:ok, _pid} = start_supervised({Slots, max: max, name: name})
    name
  end

  defp start_poller(slots, opts \\ []) do
    opts = Keyword.merge([name: unique_poller_name(), slots: slots], opts)
    start_supervised({Poller, opts})
  end

  defp expect_register(bypass, free_slots \\ 2) do
    Bypass.expect_once(bypass, "POST", "/internal/work/register", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["free_slots"] == free_slots
      Plug.Conn.resp(conn, 204, "")
    end)
  end

  defp expect_accept(bypass, parent) do
    Bypass.expect(bypass, "POST", "/internal/work/accept", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:accept, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"ok":true}))
    end)
  end

  defp expect_poll_sequence(bypass, offers, parent) do
    table = :ets.new(:poll_offers, [:set, :public])
    :ets.insert(table, {:offers, offers})

    Bypass.expect(bypass, "POST", "/internal/work/poll", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:poll, Jason.decode!(body)})

      offer =
        case :ets.lookup(table, :offers) do
          [{:offers, [next | rest]}] ->
            :ets.insert(table, {:offers, rest})
            next

          _ ->
            nil
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"offer" => offer}))
    end)
  end

  defp expect_complete(bypass, parent, assert_fun) do
    Bypass.expect(bypass, "POST", "/internal/work/complete", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert_fun.(decoded)
      send(parent, {:complete, decoded})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"ok":true}))
    end)
  end

  describe "configure/1" do
    test "activates an idle poller after enrollment credentials appear" do
      bypass = Bypass.open()
      parent = self()
      token = "worker-configure-#{System.unique_integer([:positive])}"

      Application.delete_env(:omashiki, :manager_url)
      Application.delete_env(:omashiki, :worker_token)
      put_env(:worker_executor, Omashiki.Worker.PollerTest.FakeExecutor)
      put_env(:worker_poll_interval_ms, @poll_interval_ms)

      Bypass.expect_once(bypass, "POST", "/internal/work/register", fn conn ->
        send(parent, :registered)
        Plug.Conn.resp(conn, 204, "")
      end)

      Bypass.stub(bypass, "POST", "/internal/work/poll", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"offer":null}))
      end)

      slots = start_slots!()
      poller = start_supervised!({Poller, name: unique_poller_name(), slots: slots})

      put_env(:manager_url, "http://127.0.0.1:#{bypass.port}")
      put_env(:worker_token, token)

      assert :ok = Poller.configure(server: poller)
      assert_receive :registered, 2_000
    end
  end

  defp stub_heartbeat(bypass) do
    Bypass.stub(bypass, "POST", "/internal/work/heartbeat", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"cancel":false}))
    end)
  end

  defp unique_poller_name do
    :"Omashiki.Worker.Poller.Test.#{System.unique_integer([:positive])}"
  end

  defp put_env(key, value) do
    Application.put_env(:omashiki, key, value)
  end

  defp restore_env(key) do
    Application.delete_env(:omashiki, key)
  end
end
