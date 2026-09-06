defmodule Omashiki.Worker.StateTest do
  @moduledoc """
  One machine, many houses. Enrollment is a list keyed by house id.
  """

  use ExUnit.Case, async: false

  alias Omashiki.Worker.State

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "worker-state-#{System.unique_integer([:positive])}.json"
      )

    previous = Application.get_env(:omashiki, :worker_state_path)
    Application.put_env(:omashiki, :worker_state_path, path)

    on_exit(fn ->
      File.rm(path)

      if previous do
        Application.put_env(:omashiki, :worker_state_path, previous)
      else
        Application.delete_env(:omashiki, :worker_state_path)
      end
    end)

    {:ok, path: path}
  end

  test "enrolling two houses keeps both; re-enrolling one replaces only it", %{path: path} do
    assert {:ok, [%{id: "ana"}]} =
             State.enroll(%{
               "manager_id" => "ana",
               "manager_url" => "http://ana.test/",
               "worker_token" => "a1"
             })

    assert {:ok, [%{id: "ana"}, %{id: "joao"}]} =
             State.enroll(%{
               manager_id: "joao",
               manager_url: "http://joao.test",
               worker_token: "j1"
             })

    assert File.exists?(path)
    assert File.stat!(path).mode |> rem(0o1000) == 0o600

    assert {:ok, [%{id: "joao", token: "j1"}, %{id: "ana", url: "http://ana.test", token: "a2"}]} =
             State.enroll(%{manager_id: "ana", manager_url: "http://ana.test", worker_token: "a2"})

    assert {:ok, %{managers: [%{id: "joao"}, %{id: "ana"}]}} = State.load()
  end

  test "removing a house leaves the others untouched", %{path: _path} do
    {:ok, _} = State.enroll(%{id: "ana", url: "http://ana.test", token: "a"})
    {:ok, _} = State.enroll(%{id: "joao", url: "http://joao.test", token: "j"})

    assert {:ok, [%{id: "joao"}]} = State.remove("ana")
    assert {:ok, [%{id: "joao"}]} = State.remove("ghost")
    assert State.managers() == [%{id: "joao", url: "http://joao.test", token: "j"}]
  end

  test "an id is derived from the host when none is given" do
    assert {:ok, [%{id: "manager.test"}]} =
             State.enroll(%{manager_url: "http://manager.test:9090/", worker_token: "secret"})
  end

  test "rejects invalid manager URLs and duplicate ids" do
    assert :error = State.enroll(%{manager_url: "not-a-url", worker_token: "secret"})
    assert :error = State.enroll(%{manager_url: "", worker_token: "secret"})
    assert :error = State.enroll(%{manager_url: "http://x.test", worker_token: ""})

    assert :error =
             State.save(%{
               managers: [
                 %{id: "a", url: "http://a.test", token: "1"},
                 %{id: "a", url: "http://b.test", token: "2"}
               ]
             })
  end

  test "a pre-list single-house file still loads as one entry", %{path: path} do
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{"manager_url" => "http://saved.test", "worker_token" => "tok"})
    )

    assert :ok = State.restore!()
    assert [%{id: "saved.test", url: "http://saved.test", token: "tok"}] = State.managers()

    assert {:ok, [%{id: "saved.test"}, %{id: "other"}]} =
             State.enroll(%{id: "other", url: "http://other.test", token: "o"})
  end

  test "clear forgets everything", %{path: path} do
    {:ok, _} = State.enroll(%{id: "ana", url: "http://ana.test", token: "a"})
    assert :ok = State.clear()
    refute File.exists?(path)
    assert State.load() == :error
    assert State.managers() == []
  end
end
