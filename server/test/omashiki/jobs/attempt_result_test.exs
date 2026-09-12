defmodule Omashiki.Jobs.AttemptResultTest do
  use ExUnit.Case, async: true

  alias Omashiki.Jobs.AttemptResult
  alias Omashiki.Jobs.Job

  test "truncates summary to 4 KiB" do
    assert AttemptResult.truncate_summary(String.duplicate("a", 5_000))
           |> byte_size() == 4_096
  end

  test "drops malformed change lists" do
    assert AttemptResult.sanitize_changes(%{"files" => ["hello.py"]}) == nil
    assert AttemptResult.sanitize_changes("nope") == nil
  end

  test "rebuilds change totals from trusted file entries" do
    assert AttemptResult.sanitize_changes(%{
             "files_changed" => 99,
             "insertions" => 99,
             "deletions" => 99,
             "files" => [%{"path" => "hello.py", "insertions" => 2, "deletions" => 1}]
           }) == %{
             "files_changed" => 1,
             "insertions" => 2,
             "deletions" => 1,
             "files" => [%{"path" => "hello.py", "insertions" => 2, "deletions" => 1}]
           }
  end

  test "rejects javascript compare URLs" do
    assert AttemptResult.sanitize_compare_url("javascript:alert(1)") == nil
    assert AttemptResult.sanitize_compare_url("http://evil.example/compare/a...b") == nil
  end

  test "accepts GitHub HTTPS compare URLs" do
    url = "https://github.com/acme/repo/compare/a...b"
    assert AttemptResult.sanitize_compare_url(url) == url
  end

  test "recomputes compare_url from the admitted remote" do
    job = %Job{admitted_repository: %{"remote" => "https://github.com/acme/omashiki.git"}}
    base = String.duplicate("a", 40)
    head = String.duplicate("b", 40)

    assert AttemptResult.resolve_compare_url(
             job,
             base,
             head,
             "javascript:alert(1)"
           ) == "https://github.com/acme/omashiki/compare/#{base}...#{head}"
  end
end
