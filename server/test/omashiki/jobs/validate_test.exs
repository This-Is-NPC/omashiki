defmodule Omashiki.Jobs.ValidateTest do
  # Not async: one test points :gitleaks_cli at a missing executable.
  use ExUnit.Case, async: false

  alias Omashiki.Jobs.SecretScan.Finding
  alias Omashiki.Jobs.Validate

  # A made-up GitHub personal access token: the prefix and length gitleaks
  # recognises, no real credential.
  @github_token "ghp_" <> "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8"

  setup do
    root = Path.join(System.tmp_dir!(), "omashiki-validate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "reports each secret with a redacted match and a stable fingerprint", %{root: root} do
    write!(root, "docs/release.md", "# Release\n\nexport GH=#{@github_token}\n")

    assert {:error, {:secret_found, [finding]}} =
             Validate.scan(root, ["docs/release.md"], 64)

    assert %Finding{file: "docs/release.md", line: 3, rule_id: "github-pat"} = finding
    assert finding.match == "REDACTED"
    assert finding.description =~ "GitHub"
    assert finding.fingerprint =~ ~r/\A[0-9a-f]{64}\z/
    refute inspect(finding) =~ @github_token

    # The fingerprint follows the secret, not its line.
    write!(root, "docs/release.md", "# Release\n\nNotes.\n\nexport GH=#{@github_token}\n")

    assert {:error, {:secret_found, [moved]}} = Validate.scan(root, ["docs/release.md"], 64)
    assert moved.line == 5
    assert moved.fingerprint == finding.fingerprint
  end

  test "finds an AWS access key in any file name", %{root: root} do
    write!(root, ".env", "AWS_ACCESS_KEY_ID=AKIA" <> "QWERTYUIOPASDFGH\n")

    assert {:error, {:secret_found, [%Finding{file: ".env", rule_id: "aws-access-token"}]}} =
             Validate.scan(root, [".env"], 40)
  end

  test "scans only the paths it is given", %{root: root} do
    write!(root, "old/leak.txt", "export GH=#{@github_token}\n")
    write!(root, "new.txt", "hello\n")

    assert :ok = Validate.scan(root, ["new.txt"], 6)
  end

  test "ignores gitleaks configuration and allow comments the output carries", %{root: root} do
    write!(root, ".gitleaks.toml", "[extend]\nuseDefault = false\n")
    write!(root, ".gitleaksignore", "")
    write!(root, "notes.md", "export GH=#{@github_token} # gitleaks:allow\n")

    assert {:error, {:secret_found, [%Finding{file: "notes.md"}]}} =
             Validate.scan(root, [".gitleaks.toml", ".gitleaksignore", "notes.md"], 90)
  end

  test "accepts prose about tokens and passwords", %{root: root} do
    write!(
      root,
      "token-rotation.md",
      "# Token rotation\n\nRotate the API token every 90 days. The password must be strong.\n"
    )

    assert :ok = Validate.scan(root, ["token-rotation.md"], 90)
  end

  test "fails closed when gitleaks is missing", %{root: root} do
    Application.put_env(:omashiki, :gitleaks_cli, "/nonexistent/gitleaks")
    on_exit(fn -> Application.delete_env(:omashiki, :gitleaks_cli) end)
    write!(root, "hello.txt", "hello\n")

    assert {:error, {:secret_scan_unavailable, :not_found}} =
             Validate.scan(root, ["hello.txt"], 6)
  end

  test "rejects a symlink", %{root: root} do
    File.write!(Path.join(root, "real.txt"), "ok\n")
    File.ln_s!("real.txt", Path.join(root, "link.txt"))

    assert {:error, {:symlink_path, "link.txt"}} =
             Validate.scan(root, ["link.txt"], 3)
  end

  test "rejects a protected path", %{root: root} do
    write!(root, ".ssh/config", "Host example\n")

    assert {:error, {:protected_path, ".ssh/config"}} =
             Validate.scan(root, [".ssh/config"], 13)
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

  defp write!(root, relative, content) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
