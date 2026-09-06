defmodule Omashiki.Worker.StateTest do
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

      Application.delete_env(:omashiki, :manager_url)
      Application.delete_env(:omashiki, :worker_token)
    end)

    {:ok, path: path}
  end

  test "save, load, apply, and clear round-trip", %{path: path} do
    assert :ok = State.save(%{manager_url: "http://manager.test:9090/", worker_token: "secret"})
    assert File.exists?(path)

    assert {:ok, %{manager_url: "http://manager.test:9090", worker_token: "secret"}} = State.load()
    assert Application.get_env(:omashiki, :manager_url) == "http://manager.test:9090"
    assert Application.get_env(:omashiki, :worker_token) == "secret"

    assert :ok = State.clear()
    refute File.exists?(path)
    assert State.load() == :error
  end

  test "rejects invalid manager URLs" do
    assert :error = State.save(%{manager_url: "not-a-url", worker_token: "secret"})
    assert :error = State.save(%{manager_url: "", worker_token: "secret"})
  end

  test "restore! reapplies manager_url and worker_token from disk", %{path: path} do
    Application.delete_env(:omashiki, :manager_url)
    Application.delete_env(:omashiki, :worker_token)

    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{"manager_url" => "http://saved.test", "worker_token" => "tok"})
    )

    assert :ok = State.restore!()
    assert Application.get_env(:omashiki, :manager_url) == "http://saved.test"
    assert Application.get_env(:omashiki, :worker_token) == "tok"
  end

  test "save writes state file with mode 0600", %{path: path} do
    assert :ok = State.save(%{manager_url: "http://manager.test:9090/", worker_token: "secret"})
    assert File.exists?(path)
    assert File.stat!(path).mode |> rem(0o1000) == 0o600
  end
end
