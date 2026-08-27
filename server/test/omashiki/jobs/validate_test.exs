defmodule Omashiki.Jobs.ValidateTest do
  use ExUnit.Case, async: true

  alias Omashiki.Jobs.Validate

  setup do
    root = Path.join(System.tmp_dir!(), "omashiki-validate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "rejects a likely secret", %{root: root} do
    File.write!(Path.join(root, "notes.txt"), "api_key = sk-abcdefghijklmnopqrst")

    assert {:error, {:likely_secret, "notes.txt"}} =
             Validate.scan(root, ["notes.txt"], 32)
  end

  test "rejects a symlink", %{root: root} do
    File.write!(Path.join(root, "real.txt"), "ok\n")
    File.ln_s!("real.txt", Path.join(root, "link.txt"))

    assert {:error, {:symlink_path, "link.txt"}} =
             Validate.scan(root, ["link.txt"], 3)
  end

  test "rejects a protected path", %{root: root} do
    File.mkdir_p!(Path.join(root, ".ssh"))
    File.write!(Path.join(root, ".ssh/id_ed25519"), "not-a-key\n")

    assert {:error, {:protected_path, ".ssh/id_ed25519"}} =
             Validate.scan(root, [".ssh/id_ed25519"], 10)
  end

  test "rejects oversized output", %{root: root} do
    File.write!(Path.join(root, "blob.bin"), "x")

    assert {:error, {:oversized_output, 101, 100}} =
             Validate.scan(root, ["blob.bin"], 101, max_bytes: 100)
  end

  test "accepts ordinary output", %{root: root} do
    File.write!(Path.join(root, "hello.txt"), "hello\n")
    assert :ok = Validate.scan(root, ["hello.txt"], 6)
  end
end
