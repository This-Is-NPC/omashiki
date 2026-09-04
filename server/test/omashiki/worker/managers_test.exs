defmodule Omashiki.Worker.ManagersTest do
  use ExUnit.Case, async: false

  alias Omashiki.Worker.Managers

  setup do
    on_exit(fn ->
      Application.delete_env(:omashiki, :worker_managers)
      Application.delete_env(:omashiki, :manager_url)
      Application.delete_env(:omashiki, :worker_token)
    end)

    :ok
  end

  test "singleton env synthesizes one manager from host" do
    Application.put_env(:omashiki, :manager_url, "http://manager-a.test:9090/")
    Application.put_env(:omashiki, :worker_token, "secret-token")

    assert [%{id: "manager-a.test", url: "http://manager-a.test:9090", token: "secret-token"}] =
             Managers.configured()

    assert Managers.present?()
  end

  test "JSON list normalizes entries" do
    Application.put_env(:omashiki, :worker_managers, [
      %{"url" => "http://a.test/", "token" => "a", "id" => "mgr a"},
      %{url: "http://b.test", token: "b"}
    ])

    assert [
             %{id: "mgr-a", url: "http://a.test", token: "a"},
             %{id: "b.test", url: "http://b.test", token: "b"}
           ] = Managers.configured()
  end

  test "skips incomplete entries" do
    Application.put_env(:omashiki, :worker_managers, [
      %{"url" => "http://a.test", "token" => ""},
      %{"url" => "", "token" => "tok"},
      %{"url" => "http://ok.test", "token" => "good"}
    ])

    assert [%{id: "ok.test", url: "http://ok.test", token: "good"}] = Managers.configured()
  end

  test "configured is empty when nothing is set" do
    assert Managers.configured() == []
    refute Managers.present?()
  end
end
