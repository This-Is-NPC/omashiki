defmodule Omashiki.Jobs.FailureTest do
  use ExUnit.Case, async: true

  alias Omashiki.Jobs.Failure

  @known [
    {:harness_not_ready, "harness_not_ready", "readiness check"},
    {:harness_unreachable_no_network, "harness_unreachable_no_network", "has no network"},
    {:docker_unavailable, "docker_unavailable", "Docker is not available"},
    {%{"message" => "Duplicate mount point: /tmp"}, "docker_error",
     "Docker refused the request: Duplicate mount point: /tmp"},
    {{:bootstrap_failed, 2, "npm ERR!"}, "bootstrap_failed", "exited with code 2"},
    {{:bootstrap_exec, :timeout}, "bootstrap_failed", "could not run: A call to Docker"},
    {:timeout, "timeout", "did not finish in time"},
    {{:invalid_argv, :unsafe_executable}, "invalid_step", "not allowed: unsafe_executable"},
    {{:invalid_step, "pre-1"}, "invalid_step", "Step pre-1"},
    {:cancelled, "cancelled", "The job was cancelled."},
    {:failed, "failed", "The job failed."},
    {{:attempt_already_terminal, "cancelled"}, "cancelled", "cancelled while its attempt ran"},
    {{:attempt_already_terminal, "failed"}, "attempt_already_terminal", "already failed"},
    {{:stale_attempt, 3}, "stale_attempt", "Attempt 3 stopped renewing its lease"},
    {{:orphaned_dispatch, 1}, "orphaned_dispatch", "No dispatch remained"},
    {{:dependency_failed, "job-a", "failed"}, "dependency_failed",
     "Dependency job job-a ended failed."},
    {{:dispatch_failed, :killed}, "dispatch_failed", "could not be dispatched: :killed"},
    {{:attempt_process_exit, :killed}, "attempt_process_exit", "exited: :killed"},
    {{:runner_exception, %RuntimeError{message: "boom"}}, "runner_crash", "crashed: boom"},
    {{:runner_throw, :exit, :shutdown}, "runner_crash", "crashed: exit :shutdown"},
    {{:finalization_failed, :harness_not_ready}, "finalization_failed",
     "could not be saved: The agent harness did not pass"},
    {{:claude_exit, 1, "rate limited"}, "harness_exit", "exited with code 1"}
  ]

  for {reason, code, message} <- @known do
    test "#{code} from #{inspect(reason)}" do
      reason = unquote(Macro.escape(reason))
      error = Failure.error(reason)

      assert error["code"] == unquote(code)
      assert error["message"] =~ unquote(message)
      assert error["details"]["reason"] == inspect(reason, limit: 50)
    end
  end

  test "exit codes and output stay structured" do
    assert %{"details" => %{"exit_code" => 2, "output" => "npm ERR!"}} =
             Failure.error({:bootstrap_failed, 2, "npm ERR!"})

    assert %{"details" => %{"exit_code" => 1, "output" => "rate limited"}} =
             Failure.error({:claude_exit, 1, "rate limited"})

    assert %{"details" => %{"attempt" => 3}} = Failure.error({:stale_attempt, 3})
  end

  test "records the step that failed" do
    assert %{"details" => %{"step" => "provision"}} =
             Failure.error(:harness_not_ready, "provision")
  end

  test "an unknown reason still reads as a record" do
    assert %{"code" => "attempt_failed", "message" => "The attempt failed: {:weird, 1}"} =
             Failure.error({:weird, 1})

    assert %{"code" => "attempt_failed", "message" => "The attempt failed: plain text"} =
             Failure.error("plain text")

    assert %{"code" => "attempt_failed"} = Failure.error({:other_exit, :not_a_code, "x"})
  end

  test "a long reason is bounded" do
    error = Failure.error(String.duplicate("x", 20_000))

    assert byte_size(error["message"]) == 1_024
    assert byte_size(error["details"]["reason"]) == 4_096
  end

  test "bytes that are not text are stored as their inspect" do
    error = Failure.error({:bootstrap_failed, 1, <<0xFF, 0>>})

    assert error["details"]["output"] == inspect(<<0xFF, 0>>)
    assert Jason.encode!(error)
  end

  test "event data carries the code and a bounded message" do
    error = Failure.error(%{"message" => String.duplicate("é", 400)})

    assert %{"error_code" => "docker_error", "error_message" => message} =
             Failure.event_data(error)

    assert byte_size(message) <= 255
    assert String.valid?(message)
    assert Failure.event_data(%{"code" => "runner_failed"}) == %{"error_code" => "runner_failed"}
  end
end
