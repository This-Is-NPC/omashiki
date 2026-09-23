defmodule Omashiki.Jobs.Failure do
  @moduledoc """
  The failure record of a job, an attempt, or a step.

  Every record has a stable `code`, a `message` an operator can read without
  the server logs, and structured `details`. The runner, the container
  manager, recovery, and dispatch fail with internal terms; this module is the
  one place that names them. A term it does not know still becomes a record,
  with code `attempt_failed` and the term itself as the message.
  """

  @max_message_bytes 1_024
  @max_detail_bytes 4_096
  @max_event_bytes 255
  # Findings a secret_found message names; its details keep more.
  @max_listed_findings 3
  @max_detail_findings 50

  @doc """
  Build the failure record for `reason`.

  `step` is the key of the step that returned the reason, when one did.
  """
  def error(reason, step \\ nil) do
    {code, message, details} = describe(reason) || fallback(reason)

    details =
      details
      |> Map.put("reason", truncate(inspect(reason, limit: 50), @max_detail_bytes))
      |> put_step(step)

    %{"code" => code, "message" => truncate(message, @max_message_bytes), "details" => details}
  end

  @doc "Terminal event data for a failure record: its code and a bounded message."
  def event_data(error) when is_map(error) do
    code = Map.get(error, "code", Map.get(error, :code))
    message = Map.get(error, "message", Map.get(error, :message))

    %{"error_code" => if(is_binary(code), do: code, else: "failed")}
    |> put_message(message)
  end

  def event_data(_error), do: %{"error_code" => "failed"}

  defp describe(:harness_not_ready),
    do: {"harness_not_ready", "The agent harness did not pass its readiness check in time.", %{}}

  defp describe(:harness_unreachable_no_network),
    do:
      {"harness_unreachable_no_network",
       "The container has no network, so its HTTP harness cannot be reached. Use a CLI " <>
         "harness, or give the environment a network with OMASHIKI_AGENT_NETWORK_MODE.", %{}}

  defp describe(:docker_unavailable),
    do: {"docker_unavailable", "Docker is not available on the node that ran the attempt.", %{}}

  defp describe({:image_missing, image}),
    do:
      {"image_missing",
       "Image #{image} is not on the node that ran the attempt. " <>
         Omashiki.Runtimes.provide_image(image), %{"image" => image}}

  # The Docker Engine API answers a refused request with `{"message": ...}`.
  defp describe(%{"message" => message}) when is_binary(message),
    do: {"docker_error", "Docker refused the request: #{message}", %{}}

  defp describe({:bootstrap_failed, exit_code, output}),
    do:
      {"bootstrap_failed", "The container startup command exited with code #{exit_code}.",
       %{"exit_code" => exit_code, "output" => output_detail(output)}}

  defp describe({:bootstrap_exec, reason}),
    do: {"bootstrap_failed", "The container startup command could not run: #{cause(reason)}", %{}}

  defp describe(:timeout),
    do: {"timeout", "A call to Docker or to the agent harness did not finish in time.", %{}}

  defp describe({:invalid_argv, why}),
    do: {"invalid_step", "A step command is not allowed: #{why}.", %{}}

  defp describe({:invalid_step, key}),
    do: {"invalid_step", "Step #{key} has an invalid condition or timeout.", %{}}

  defp describe(:cancelled), do: {"cancelled", "The job was cancelled.", %{}}
  defp describe(:failed), do: {"failed", "The job failed.", %{}}

  defp describe({:attempt_already_terminal, "cancelled"}),
    do: {"cancelled", "The job was cancelled while its attempt ran.", %{}}

  defp describe({:attempt_already_terminal, status}),
    do:
      {"attempt_already_terminal", "The job was already #{status} while its attempt ran.",
       %{"status" => status}}

  defp describe({:stale_attempt, number}),
    do:
      {"stale_attempt",
       "Attempt #{number} stopped renewing its lease. The node that ran it may have stopped.",
       %{"attempt" => number}}

  defp describe({:orphaned_dispatch, number}),
    do:
      {"orphaned_dispatch", "No dispatch remained to run this queued job.",
       %{"attempt" => number}}

  defp describe({:dependency_failed, job_id, status}),
    do:
      {"dependency_failed", "Dependency job #{job_id} ended #{status}.",
       %{"dependency_job_id" => job_id, "dependency_status" => status}}

  defp describe({:dispatch_failed, reason}),
    do: {"dispatch_failed", "The job could not be dispatched: #{cause(reason)}", %{}}

  defp describe({:attempt_process_exit, reason}),
    do: {"attempt_process_exit", "The attempt process exited: #{cause(reason)}", %{}}

  defp describe({:runner_exception, error}) when is_exception(error),
    do: {"runner_crash", "The runner crashed: #{Exception.message(error)}", %{}}

  defp describe({:runner_throw, kind, reason}),
    do: {"runner_crash", "The runner crashed: #{kind} #{inspect(reason)}", %{}}

  defp describe({:finalization_failed, reason}),
    do:
      refusal(reason) ||
        {"finalization_failed", "The attempt output could not be saved: #{cause(reason)}", %{}}

  defp describe({:agent_waiting_for_permission, permission, patterns, subagent?}) do
    asker = if subagent?, do: "A subagent", else: "The agent"
    on = if patterns == [], do: "", else: " on #{Enum.join(patterns, ", ")}"

    {"agent_waiting_for_permission",
     "#{asker} asked for the #{permission} permission#{on}. Nobody can approve it in a " <>
       "container, so the attempt failed.",
     %{"permission" => permission, "patterns" => patterns, "subagent" => subagent?}}
  end

  # Harness adapters report a non-zero exit as `{:<harness>_exit, code, output}`.
  defp describe({tag, exit_code, output}) when is_atom(tag) and is_integer(exit_code) do
    if String.ends_with?(Atom.to_string(tag), "_exit"),
      do:
        {"harness_exit", "The agent harness exited with code #{exit_code}.",
         %{"exit_code" => exit_code, "output" => output_detail(output)}}
  end

  defp describe(_reason), do: nil

  # Why `Omashiki.Jobs.Validate` refused the output, or nil for any other reason.
  defp refusal({:secret_found, findings}) do
    {listed, rest} = Enum.split(findings, @max_listed_findings)
    where = Enum.map(listed, &"#{&1.file} line #{&1.line} (rule #{&1.rule_id})")
    where = if rest == [], do: where, else: where ++ ["#{length(rest)} more"]
    noun = if match?([_], findings), do: "a secret", else: "secrets"

    {"secret_found", "Output was held back: gitleaks found #{noun} in #{sentence(where)}.",
     %{
       "finding_count" => length(findings),
       "findings" => findings |> Enum.take(@max_detail_findings) |> Enum.map(&finding_detail/1)
     }}
  end

  defp refusal({:protected_path, path}),
    do:
      {"protected_path", "Output writes to #{path}, a protected path, so it was not published.",
       %{"path" => path}}

  defp refusal({:symlink_path, path}),
    do:
      {"symlink_path", "Output contains #{path}, a symbolic link, so it was not published.",
       %{"path" => path}}

  defp refusal({:oversized_output, changed_bytes, max_bytes}),
    do:
      {"oversized_output",
       "Output changes #{size(changed_bytes)}, more than the #{size(max_bytes)} limit, " <>
         "so it was not published.",
       %{"changed_bytes" => changed_bytes, "max_bytes" => max_bytes}}

  defp refusal({:secret_scan_unavailable, reason}),
    do:
      {"secret_scan_unavailable",
       "Output was held back: #{scanner_cause(reason)}, so it could not be scanned for secrets.",
       %{}}

  defp refusal(_reason), do: nil

  defp finding_detail(finding) do
    %{
      "file" => finding.file,
      "line" => finding.line,
      "rule_id" => finding.rule_id,
      "description" => finding.description,
      "match" => finding.match,
      "fingerprint" => finding.fingerprint
    }
  end

  defp scanner_cause(:not_found), do: "gitleaks is not installed on the node that ran the attempt"
  defp scanner_cause(:timeout), do: "gitleaks did not finish in time"

  defp scanner_cause({:exit, status, output}),
    do: "gitleaks exited with code #{status} (#{output})"

  defp scanner_cause(reason), do: "gitleaks could not run (#{inspect(reason, limit: 20)})"

  defp sentence([one]), do: one
  defp sentence(items), do: Enum.join(Enum.drop(items, -1), ", ") <> " and " <> List.last(items)

  defp size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp size(bytes), do: size(bytes / 1024, ["KiB", "MiB", "GiB"])

  defp size(value, [unit | rest]) when value < 1024 or rest == [] do
    rounded = Float.round(value, 1)
    number = if rounded == trunc(rounded), do: trunc(rounded), else: rounded
    "#{number} #{unit}"
  end

  defp size(value, [_unit | rest]), do: size(value / 1024, rest)

  defp fallback(reason), do: {"attempt_failed", "The attempt failed: #{cause(reason)}", %{}}

  # A known inner reason reads as its message; anything else as the term.
  defp cause(reason) do
    case describe(reason) do
      {_code, message, _details} -> message
      nil when is_binary(reason) -> reason
      nil -> inspect(reason, limit: 20)
    end
  end

  defp put_step(details, step) when is_binary(step), do: Map.put(details, "step", step)
  defp put_step(details, _step), do: details

  defp put_message(data, message) when is_binary(message),
    do: Map.put(data, "error_message", truncate(message, @max_event_bytes))

  defp put_message(data, _message), do: data

  defp output_detail(output) when is_binary(output), do: truncate(output, @max_detail_bytes)
  defp output_detail(output), do: truncate(inspect(output), @max_detail_bytes)

  # Records are stored as JSON: bytes that are not text are kept as their inspect.
  defp truncate(text, max) when is_binary(text) do
    if String.valid?(text) and not String.contains?(text, <<0>>),
      do: prefix(text, max),
      else: prefix(inspect(text), max)
  end

  defp prefix(text, max) when byte_size(text) <= max, do: text

  defp prefix(text, max) do
    case :unicode.characters_to_binary(binary_part(text, 0, max)) do
      valid when is_binary(valid) -> valid
      {:incomplete, valid, _rest} -> valid
      {:error, valid, _rest} -> valid
    end
  end
end
