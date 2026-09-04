defmodule Omashiki.Worker.SlotsTest do
  use ExUnit.Case, async: false

  alias Omashiki.Worker.Slots

  defp start_slots(opts \\ []) do
    name = :"slots_test_#{System.unique_integer([:positive])}"
    opts = Keyword.put_new(opts, :name, name)
    {:ok, _pid} = start_supervised({Slots, opts})
    name
  end

  test "max 2: two acquires succeed, third is full" do
    name = start_slots(max: 2)

    assert Slots.try_acquire(name) == :ok
    assert Slots.try_acquire(name) == :ok
    assert Slots.try_acquire(name) == {:error, :full}
    assert Slots.available(name) == 0
  end

  test "release then acquire again" do
    name = start_slots(max: 2)

    assert Slots.try_acquire(name) == :ok
    assert Slots.release(name) == :ok
    assert Slots.try_acquire(name) == :ok

    snap = Slots.snapshot(name)
    assert snap.used == 1
    assert snap.free == 1
    assert snap.max == 2
  end

  test "concurrent acquires cannot exceed max" do
    name = start_slots(max: 2)
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          results = for _ <- 1..3, do: Slots.try_acquire(name)
          send(parent, {:results, results})
        end)
      end

    results =
      for _ <- 1..2 do
        assert_receive {:results, r}
        r
      end
      |> List.flatten()

    Enum.each(tasks, &Task.await/1)

    assert Enum.count(results, &(&1 == :ok)) == 2
    assert Enum.count(results, &(&1 == {:error, :full})) == 4
  end

  test "extra release does not go negative" do
    name = start_slots(max: 2)

    assert Slots.release(name) == :ok
    assert Slots.release(name) == :ok
    assert Slots.available(name) == 2

    snap = Slots.snapshot(name)
    assert snap.used == 0
    assert snap.free == 2
  end

  describe "default max from HostSettings" do
    setup do
      original = Application.get_env(:omashiki, :max_concurrent_containers)
      Application.put_env(:omashiki, :max_concurrent_containers, 3)

      on_exit(fn ->
        if original do
          Application.put_env(:omashiki, :max_concurrent_containers, original)
        else
          Application.delete_env(:omashiki, :max_concurrent_containers)
        end
      end)

      :ok
    end

    test "start_link without :max uses HostSettings.get_max_concurrent_containers/0" do
      name = start_slots()

      snap = Slots.snapshot(name)
      assert snap.max == 3
    end
  end
end
