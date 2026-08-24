defmodule Omashiki.Runtimes.CacheGcTest do
  use ExUnit.Case, async: false

  alias Omashiki.Runtimes.{CacheGc, CacheGroup, CacheMaintenance, CacheSnapshot}

  setup do
    root = Path.join(System.tmp_dir!(), "omashiki-cache-gc-#{System.unique_integer([:positive])}")
    cache_root = Path.join(root, "payload")
    metadata_root = Path.join(root, "metadata")
    host = Path.join(cache_root, "global")
    File.mkdir_p!(host)

    previous_root = System.get_env("OMASHIKI_CACHE_ROOT")
    System.put_env("OMASHIKI_CACHE_ROOT", cache_root)

    on_exit(fn ->
      restore_env("OMASHIKI_CACHE_ROOT", previous_root)
      File.rm_rf(root)
    end)

    {:ok, root: root, host: host, metadata_root: metadata_root}
  end

  test "snapshots recursive size and stores metadata outside the mounted payload", ctx do
    group = group(ctx.host)
    File.mkdir_p!(Path.join(ctx.host, "npm/content"))
    File.write!(Path.join(ctx.host, "npm/content/index"), String.duplicate("a", 37))
    File.write!(Path.join(ctx.host, "toolchain"), String.duplicate("b", 11))

    assert {:ok, snapshot} = CacheGc.snapshot(group, metadata_root: ctx.metadata_root)
    assert snapshot.size_bytes == 48
    assert Enum.map(snapshot.entries, & &1.name) == ["npm", "toolchain"]
    assert snapshot.last_accessed_at

    metadata_path = Path.join(ctx.metadata_root, "global.json")
    assert File.exists?(metadata_path)
    refute String.starts_with?(metadata_path, ctx.host)
    assert {:ok, metadata} = metadata_path |> File.read() |> elem(1) |> Jason.decode()
    assert metadata["version"] == 1
    assert metadata["size_bytes"] == 48
  end

  test "evicts oldest top-level ecosystem directories until the group fits", ctx do
    group = group(ctx.host, max_size_mb: 1)
    old = Path.join(ctx.host, "npm")
    new = Path.join(ctx.host, "mise")
    File.mkdir_p!(old)
    File.mkdir_p!(new)
    File.write!(Path.join(old, "cache"), String.duplicate("a", 800_000))
    File.write!(Path.join(new, "cache"), String.duplicate("b", 400_000))
    :ok = File.touch(old, {{2020, 1, 1}, {0, 0, 0}})
    :ok = File.touch(new, {{2025, 1, 1}, {0, 0, 0}})

    assert {:ok, result} = CacheGc.enforce(group, metadata_root: ctx.metadata_root)
    assert Enum.map(result.evicted, & &1.name) == ["npm"]
    refute File.exists?(old)
    assert File.dir?(new)
    assert result.snapshot.size_bytes <= 1_048_576
    refute result.over_limit?
  end

  test "protected enforcement leaves active payload untouched", ctx do
    group = group(ctx.host, max_size_mb: 1)
    entry = Path.join(ctx.host, "cargo")
    File.mkdir_p!(entry)
    File.write!(Path.join(entry, "index"), String.duplicate("x", 1_100_000))

    assert {:ok, result} =
             CacheGc.enforce(group, metadata_root: ctx.metadata_root, protected?: true)

    assert result.protected?
    assert result.evicted == []
    assert File.dir?(entry)
  end

  test "purge removes only safe children and never follows a top-level symlink", ctx do
    group = group(ctx.host)
    keep_outside = Path.join(ctx.root, "outside")
    File.mkdir_p!(keep_outside)
    File.write!(Path.join(keep_outside, "secret"), "must remain")
    File.mkdir_p!(Path.join(ctx.host, "npm"))
    File.write!(Path.join(ctx.host, "npm/index"), "cache")
    :ok = File.ln_s(keep_outside, Path.join(ctx.host, "linked"))

    assert {:ok, result} = CacheGc.purge(group, metadata_root: ctx.metadata_root)
    assert Enum.map(result.removed, & &1.name) == ["npm"]

    assert Enum.any?(result.skipped, fn {name, reason} ->
             name == "linked" and reason == :symlink
           end)

    refute File.exists?(Path.join(ctx.host, "npm"))
    assert File.exists?(Path.join(keep_outside, "secret"))
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(ctx.host, "linked"))
  end

  test "rejects a configured group whose host is a symlink or outside the root", ctx do
    outside = Path.join(ctx.root, "outside")
    File.mkdir_p!(outside)
    linked = Path.join(ctx.host, "linked")
    :ok = File.ln_s(outside, linked)

    assert {:error, {:cache_path, :symlink}} =
             CacheGc.snapshot(group(linked), metadata_root: ctx.metadata_root)

    assert {:error, :cache_path_outside_root} =
             CacheGc.snapshot(group(outside), metadata_root: ctx.metadata_root)
  end

  test "rejects metadata configured inside the mounted payload", ctx do
    assert {:error, :metadata_inside_cache_payload} =
             CacheGc.snapshot(group(ctx.host), metadata_root: ctx.host)
  end

  test "coordinator leases protect purge and monitor-based owners release automatically", ctx do
    group = group(ctx.host)
    File.mkdir_p!(Path.join(ctx.host, "npm"))
    File.write!(Path.join(ctx.host, "npm/index"), "cache")
    server = String.to_atom("cache-maintenance-#{System.unique_integer([:positive])}")

    start_supervised!(
      {CacheMaintenance,
       [
         name: server,
         groups: [group],
         metadata_root: ctx.metadata_root,
         events?: false,
         interval_ms: :infinity
       ]}
    )

    owner = self()
    assert {:ok, lease} = CacheMaintenance.acquire([group], owner, server)
    assert CacheMaintenance.active?("global", server)
    assert {:error, :active} = CacheMaintenance.purge("global", server)
    assert :ok = CacheMaintenance.release(lease, server)
    refute CacheMaintenance.active?("global", server)

    owner_pid = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, _lease} = CacheMaintenance.acquire([group], owner_pid, server)
    assert CacheMaintenance.active?("global", server)
    Process.exit(owner_pid, :kill)
    eventually(fn -> not CacheMaintenance.active?("global", server) end)
  end

  test "classifies empty groups as cold and populated groups as warm", ctx do
    captured_at = DateTime.utc_now()

    assert CacheSnapshot.outcome(%CacheSnapshot{
             group: "global",
             host: ctx.host,
             size_bytes: 0,
             max_size_mb: nil,
             captured_at: captured_at
           }) == :cold

    assert CacheSnapshot.outcome(%CacheSnapshot{
             group: "global",
             host: ctx.host,
             size_bytes: 1,
             max_size_mb: nil,
             captured_at: captured_at
           }) == :warm
  end

  defp group(host, attrs \\ []) do
    struct!(%CacheGroup{name: "global", host: host}, attrs)
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
