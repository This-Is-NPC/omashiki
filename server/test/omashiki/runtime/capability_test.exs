defmodule Omashiki.Runtime.CapabilityTest do
  use ExUnit.Case, async: true

  alias Omashiki.Runtime.Capability

  defmodule Boundary do
    def exec(container, argv, timeout) do
      send(self(), {:exec, container, argv, timeout})
      {:ok, %{stdout: "", exit_code: 0}}
    end
  end

  test "adapts the injected container boundary without exposing ContainerManager" do
    container = %{id: "sandbox", transport: %{"kind" => "cli"}}
    capability = Capability.from_container(container, Boundary)

    assert {:ok, _} = Capability.exec(capability, ["runner", "/tmp/input"], 5_000)
    assert_receive {:exec, ^container, ["runner", "/tmp/input"], 5_000}

    assert capability.transport == :cli
    assert capability.endpoint == nil
  end
end
