defmodule Omashiki.ApplicationBootTest do
  use ExUnit.Case, async: true

  alias Omashiki.Application

  defp child_modules(children) do
    Enum.map(children, fn
      child when is_atom(child) -> child
      {module, _} when is_atom(module) -> module
    end)
  end

  test "boot_role/0 defaults to :embedded" do
    assert Application.boot_role() == :embedded
  end

  test "children_for(:embedded) includes Repo, Endpoint, ContainerManager, Oban" do
    modules = child_modules(Application.children_for(:embedded))

    assert Omashiki.Repo in modules
    assert OmashikiWeb.Endpoint in modules
    assert Omashiki.Runtime.ContainerManager in modules
    assert Oban in modules
  end

  test "children_for(:manager) includes Repo, Endpoint, Oban; excludes runtime executors" do
    modules = child_modules(Application.children_for(:manager))

    assert Omashiki.Repo in modules
    assert OmashikiWeb.Endpoint in modules
    assert Oban in modules
    refute Omashiki.Runtime.ContainerManager in modules
    refute Omashiki.Runtime.AttemptSupervisor in modules
    refute Omashiki.Runtime.LeaseRenewer in modules
  end

  test "children_for(:worker) includes ContainerManager, AttemptSupervisor, Slots, Poller; excludes control plane" do
    modules = child_modules(Application.children_for(:worker))

    assert Omashiki.Runtime.ContainerManager in modules
    assert Omashiki.Runtime.AttemptSupervisor in modules
    assert Omashiki.Worker.Slots in modules
    assert Omashiki.Worker.Poller in modules
    assert Omashiki.Worker.Enroll.Listener in modules
    refute Omashiki.Repo in modules
    refute OmashikiWeb.Endpoint in modules
    refute Oban in modules
  end

  test "children_for(:embedded) and :manager exclude Poller and Slots" do
    embedded = child_modules(Application.children_for(:embedded))
    manager = child_modules(Application.children_for(:manager))

    refute Omashiki.Worker.Poller in embedded
    refute Omashiki.Worker.Poller in manager
    refute Omashiki.Worker.Slots in embedded
    refute Omashiki.Worker.Slots in manager
  end

  test "manager Oban child serves webhooks only" do
    [{Oban, config}] =
      Enum.filter(Application.children_for(:manager), &match?({Oban, _}, &1))

    assert Keyword.fetch!(config, :queues) == [webhooks: 5, token_audit: 1]
  end
end
