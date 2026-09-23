defmodule Omashiki.Doctor.HostProbeTest do
  use ExUnit.Case, async: true

  alias Omashiki.Doctor.HostProbe

  setup do
    root = Path.join(System.tmp_dir!(), "omashiki-probe-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn ->
      File.chmod(root, 0o700)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "a directory this process can create files in is ok and left as it was", %{root: root} do
    assert HostProbe.directory(root) == :ok
    assert File.ls!(root) == []
  end

  test "a missing directory is :enoent", %{root: root} do
    assert HostProbe.directory(Path.join(root, "missing")) == {:error, :enoent}
  end

  test "a file where the directory should be is :enotdir", %{root: root} do
    file = Path.join(root, "file")
    File.write!(file, "")

    assert HostProbe.directory(file) == {:error, :enotdir}
  end

  test "a directory that refuses new files is the file system's reason", %{root: root} do
    File.chmod!(root, 0o500)

    assert HostProbe.directory(root) == {:error, :eacces}
  end
end
