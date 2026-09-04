defmodule Omashiki.Worker.DataPlaneTest do
  use ExUnit.Case, async: false

  alias Omashiki.Worker.DataPlane

  setup do
    on_exit(fn -> Application.delete_env(:omashiki, :manager_url) end)
    :ok
  end

  test "base_url is nil when manager_url is unset" do
    Application.delete_env(:omashiki, :manager_url)

    refute DataPlane.remote?()
    assert DataPlane.base_url() == nil
  end

  test "base_url trims trailing slash" do
    Application.put_env(:omashiki, :manager_url, "http://manager.test:9090/")

    assert DataPlane.base_url() == "http://manager.test:9090"
    assert DataPlane.remote?()
  end
end
