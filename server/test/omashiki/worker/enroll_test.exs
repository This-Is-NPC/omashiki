defmodule Omashiki.Worker.EnrollTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Omashiki.Worker.{Enroll, Poller, Slots, State}

  setup do
    on_exit(fn ->
      Application.delete_env(:omashiki, :enroll_secret)
      Application.delete_env(:omashiki, :worker_state_path)
      Application.delete_env(:omashiki, :manager_url)
      Application.delete_env(:omashiki, :worker_token)
      Application.delete_env(:omashiki, :worker_executor)
    end)

    path =
      Path.join(
        System.tmp_dir!(),
        "worker-state-#{System.unique_integer([:positive])}.json"
      )

    Application.put_env(:omashiki, :worker_state_path, path)
    Application.put_env(:omashiki, :enroll_secret, "enroll-secret")
    Application.put_env(:omashiki, :worker_executor, Omashiki.Worker.Snapshot)

    on_exit(fn -> File.rm(path) end)

    :ok
  end

  test "healthz returns worker ok" do
    conn = conn(:get, "/healthz") |> call_plug()
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"role" => "worker", "status" => "ok"}
  end

  test "POST /internal/enroll persists credentials and activates the poller" do
    bypass = Bypass.open()
    parent = self()

    Bypass.expect_once(bypass, "POST", "/internal/work/register", fn conn ->
      send(parent, :registered)
      Plug.Conn.resp(conn, 204, "")
    end)

    Bypass.stub(bypass, "POST", "/internal/work/poll", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"offer":null}))
    end)

    Application.delete_env(:omashiki, :manager_url)
    Application.delete_env(:omashiki, :worker_token)

    slots = start_supervised!({Slots, max: 2, name: unique_slots()})
    start_supervised!({Poller, slots: slots})

    body =
      Jason.encode!(%{
        "manager_url" => "http://127.0.0.1:#{bypass.port}",
        "worker_token" => "worker-token"
      })

    conn =
      conn(:post, "/internal/enroll", body)
      |> put_req_header("authorization", "Bearer enroll-secret")
      |> put_req_header("content-type", "application/json")
      |> call_plug()

    assert conn.status == 204
    assert {:ok, _} = State.load()
    assert_receive :registered, 2_000
  end

  test "two houses enroll on one worker, and one can leave without the other noticing" do
    ana = Bypass.open()
    joao = Bypass.open()
    parent = self()

    for {bypass, name} <- [{ana, :ana}, {joao, :joao}] do
      Bypass.stub(bypass, "POST", "/internal/work/register", fn conn ->
        send(parent, {:registered, name})
        Plug.Conn.resp(conn, 204, "")
      end)

      Bypass.stub(bypass, "POST", "/internal/work/poll", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"offer":null}))
      end)
    end

    Application.delete_env(:omashiki, :manager_url)
    Application.delete_env(:omashiki, :worker_token)

    slots = start_supervised!({Slots, max: 2, name: unique_slots()})
    start_supervised!({Poller, slots: slots})

    assert enroll_house("ana", ana.port, "tok-ana").status == 204
    assert_receive {:registered, :ana}, 2_000

    assert enroll_house("joao", joao.port, "tok-joao").status == 204
    assert_receive {:registered, :joao}, 2_000
    assert_receive {:registered, :ana}, 2_000

    assert [%{id: "ana", token: "tok-ana"}, %{id: "joao", token: "tok-joao"}] =
             Omashiki.Worker.Managers.configured()

    listing =
      conn(:get, "/internal/enroll")
      |> put_req_header("authorization", "Bearer enroll-secret")
      |> call_plug()

    assert listing.status == 200

    assert %{"managers" => [%{"id" => "ana", "url" => _}, %{"id" => "joao", "url" => _}]} =
             Jason.decode!(listing.resp_body)

    refute listing.resp_body =~ "tok-"

    removed =
      conn(:delete, "/internal/enroll/ana")
      |> put_req_header("authorization", "Bearer enroll-secret")
      |> call_plug()

    assert removed.status == 204
    assert [%{id: "joao"}] = Omashiki.Worker.Managers.configured()
    assert_receive {:registered, :joao}, 2_000
  end

  test "returns 401 without bearer token" do
    conn =
      conn(:post, "/internal/enroll", "{}")
      |> put_req_header("content-type", "application/json")
      |> call_plug()

    assert conn.status == 401
    assert error_code(conn) == "missing_token"
  end

  test "returns 403 when enrollment is disabled" do
    Application.delete_env(:omashiki, :enroll_secret)

    conn =
      conn(:post, "/internal/enroll", "{}")
      |> put_req_header("authorization", "Bearer anything")
      |> put_req_header("content-type", "application/json")
      |> call_plug()

    assert conn.status == 403
    assert error_code(conn) == "enroll_disabled"
  end

  test "returns 403 for invalid bearer token" do
    conn =
      conn(:post, "/internal/enroll", "{}")
      |> put_req_header("authorization", "Bearer wrong")
      |> put_req_header("content-type", "application/json")
      |> call_plug()

    assert conn.status == 403
    assert error_code(conn) == "invalid_token"
  end

  test "returns 422 for invalid body" do
    conn =
      conn(:post, "/internal/enroll", ~s({"manager_url":"not-a-url","worker_token":"tok"}))
      |> put_req_header("authorization", "Bearer enroll-secret")
      |> put_req_header("content-type", "application/json")
      |> call_plug()

    assert conn.status == 422
    assert error_code(conn) == "invalid_body"
  end

  test "Enroll.valid_secret?/1 respects configured secret" do
    assert Enroll.valid_secret?("enroll-secret")
    refute Enroll.valid_secret?("wrong")
  end

  defp enroll_house(id, port, token) do
    body =
      Jason.encode!(%{
        "manager_id" => id,
        "manager_url" => "http://127.0.0.1:#{port}",
        "worker_token" => token
      })

    conn(:post, "/internal/enroll", body)
    |> put_req_header("authorization", "Bearer enroll-secret")
    |> put_req_header("content-type", "application/json")
    |> call_plug()
  end

  defp call_plug(conn) do
    conn
    |> Map.put(:secret_key_base, String.duplicate("a", 64))
    |> Omashiki.Worker.Enroll.Plug.call(Omashiki.Worker.Enroll.Plug.init([]))
  end

  defp error_code(conn) do
    conn.resp_body |> Jason.decode!() |> get_in(["error", "code"])
  end

  defp unique_slots do
    :"Omashiki.Worker.Slots.EnrollTest.#{System.unique_integer([:positive])}"
  end
end
