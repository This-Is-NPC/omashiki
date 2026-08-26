defmodule Omashiki.Harness.Pi do
  @moduledoc """
  pi 0.84 implementation of the neutral harness contract.

  pi reaches an OpenAI-compatible endpoint through a provider declared in
  `models.json` under `PI_CODING_AGENT_DIR`, so it runs entirely on the gateway
  path: the container is handed a job-bound token and a loopback base URL,
  never a provider key. Like jcode it therefore has no host-auth branch.

  That file records the token as the literal `"$PI_GATEWAY_TOKEN"`, which pi
  resolves from the environment at request time. The token therefore never
  lands on disk and never enters the exec argv, where `ps` inside the container
  would show it — the same reason jcode is configured with `--api-key-env`.

  Two things differ from `Omashiki.Harness.Jcode` and drive the code below.

  `PI_OFFLINE=1` is not an optimisation. Without it pi performs startup network
  operations against its model catalog and blocks indefinitely when that route
  is unavailable, which inside a restricted-network container is a silent boot
  failure rather than a slow start. It is part of the launch plan for that
  reason, not to save a round trip.

  `--mode json` emits a *stream* of newline-delimited events, not the single
  object jcode returns. The fold lives here rather than in the runner so the
  image stays free of a JSON parser, the same reason the prompt is composed
  host-side. Usage is summed across every assistant message in the run: pi
  reports it per turn, so reading only the final turn would under-report a
  multi-turn job by roughly its turn count.
  """

  @behaviour Omashiki.Harness.Adapter

  alias Omashiki.Credentials.Credential
  alias Omashiki.Harness.{Context, Invocation, LaunchPlan, Result, Spec}
  alias Omashiki.Jobs.Job
  alias Omashiki.Runtime.Capability
  alias Omashiki.Runtime.Claims

  @invocation_path "/tmp/omashiki-pi-invocation.txt"
  @runner_path "/usr/local/bin/omashiki-pi-runner"
  # pi's own default for this directory is ~/.pi/agent; it is pinned explicitly
  # because HOME is a tmpfs the orchestrator chooses, not the image's.
  @agent_dir "/tmp/agent-home/.pi/agent"
  @default_timeout_ms 900_000
  @default_options %{
    "invocation_path" => @invocation_path,
    "runner_path" => @runner_path,
    "timeout_ms" => @default_timeout_ms,
    "model" => nil
  }
  @option_keys Map.keys(@default_options)

  def invocation_path, do: @invocation_path
  def runner_path, do: @runner_path
  def agent_dir, do: @agent_dir

  @impl true
  def validate_options(options) when is_map(options) do
    unknown = Map.keys(options) -- @option_keys
    options = Map.merge(@default_options, options)

    cond do
      unknown != [] -> {:error, {:unknown_options, Enum.sort(unknown)}}
      not valid_path?(options["invocation_path"], "/tmp/") -> {:error, :invalid_invocation_path}
      not valid_absolute_path?(options["runner_path"]) -> {:error, :invalid_runner_path}
      not positive_timeout?(options["timeout_ms"]) -> {:error, :invalid_timeout}
      not valid_model?(options["model"]) -> {:error, :invalid_model}
      true -> :ok
    end
  end

  def validate_options(_), do: {:error, :options_must_be_a_map}

  @impl true
  def launch_plan(%Spec{runtime: runtime, options: raw_options}) do
    options = Map.merge(@default_options, raw_options)

    {:ok,
     %LaunchPlan{
       runtime: runtime,
       transport: %{
         "kind" => "cli",
         "argv" => cli_argv(options),
         "timeout_ms" => options["timeout_ms"]
       },
       startup: nil,
       readiness: %{
         "kind" => "exec",
         "argv" => [options["runner_path"], "--version"],
         "timeout_ms" => 10_000
       },
       secret: nil,
       environment: [
         "HOME=/tmp/agent-home",
         "PI_CODING_AGENT_DIR=#{@agent_dir}",
         # Not an optimisation: see the moduledoc. Without it pi blocks forever.
         "PI_OFFLINE=1"
       ],
       llm_egress: :gateway
     }}
  end

  @impl true
  def prepare(%Spec{} = spec, %Context{} = context) do
    options = Map.merge(@default_options, spec.options)

    with %Credential{} = credential <- credential(context),
         %Job{} = job <- context.job,
         {:ok, gateway_token} <- Claims.issue("gateway", job, %{credential: credential.name}),
         {:ok, prompt} <- prompt_for(job) do
      plan = launch_plan!(spec)

      {:ok,
       %{
         plan
         | secret: %{"target" => options["invocation_path"], "contents" => prompt},
           environment:
             plan.environment ++
               [
                 "PI_GATEWAY_BASE_URL=#{gateway_base_url(context)}",
                 "PI_GATEWAY_MODEL=#{credential.model}",
                 "PI_GATEWAY_TOKEN=#{gateway_token}"
               ]
       }}
    else
      nil -> {:error, :runtime_job_required}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def invoke(
        %Invocation{} = invocation,
        %Context{capability: %Capability{} = capability} = context
      ) do
    options = Map.merge(@default_options, context.profile.options)

    with :ok <- validate_invocation(invocation),
         {:ok, output} <- Capability.exec(capability, cli_argv(options), options["timeout_ms"]),
         {:ok, events} <- decode_output(output),
         {:ok, result} <- normalize_result(events) do
      {:ok, result}
    end
  end

  def invoke(%Invocation{}, %Context{}), do: {:error, :runtime_capability_unavailable}

  defp credential(%Context{credential: %Credential{} = credential}), do: credential
  defp credential(_), do: nil

  defp gateway_base_url(%Context{host_base_url: base}) when is_binary(base),
    do: String.trim_trailing(base, "/") <> "/api/v1/gateway/v1"

  defp gateway_base_url(_), do: Omashiki.Gateway.openai_base_url()

  # The context is folded in here rather than in the container so the image can
  # stay free of a JSON parser: the runner only ever reads a text file.
  defp prompt_for(%Job{payload: payload}) when is_map(payload), do: compose(payload)
  defp prompt_for(%{payload: payload}) when is_map(payload), do: compose(payload)
  defp prompt_for(%{"payload" => payload}) when is_map(payload), do: compose(payload)
  defp prompt_for(_), do: {:error, :runtime_job_payload_required}

  defp compose(payload) do
    case Map.get(payload, "instruction", Map.get(payload, :instruction)) do
      instruction when is_binary(instruction) and instruction != "" ->
        case Map.get(payload, "context", Map.get(payload, :context)) do
          context when is_map(context) ->
            {:ok, instruction <> "\n\nContext:\n" <> Jason.encode!(context)}

          _ ->
            {:ok, instruction}
        end

      _ ->
        {:error, :runtime_job_payload_required}
    end
  end

  defp cli_argv(options) do
    [options["runner_path"], options["invocation_path"]] ++
      if(options["model"], do: ["--model", options["model"]], else: [])
  end

  # pi writes one JSON event per line and interleaves nothing else on stdout,
  # but a non-JSON line is tolerated rather than fatal: a stray warning must
  # not discard a run that otherwise completed.
  defp decode_output(%{exit_code: 0, stdout: stdout}) when is_binary(stdout) do
    events =
      stdout
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, event} when is_map(event) -> [event]
          _ -> []
        end
      end)

    case events do
      [] -> {:error, {:pi_non_json_output, summarize(stdout)}}
      events -> {:ok, events}
    end
  end

  defp decode_output(%{"exit_code" => 0, "stdout" => stdout}),
    do: decode_output(%{exit_code: 0, stdout: stdout})

  defp decode_output(%{exit_code: code, stdout: stdout}),
    do: {:error, {:pi_exit, code, summarize(stdout)}}

  defp decode_output(%{"exit_code" => code, "stdout" => stdout}),
    do: decode_output(%{exit_code: code, stdout: stdout})

  defp decode_output(other), do: {:error, {:pi_invalid_exec_result, inspect(other)}}

  # `agent_end` is the single event carrying the whole conversation, so the
  # result is read from there rather than reassembled from the deltas.
  defp normalize_result(events) do
    case Enum.find(events, &(&1["type"] == "agent_end")) do
      %{"messages" => messages} when is_list(messages) ->
        assistants = Enum.filter(messages, &(&1["role"] == "assistant"))
        usage = Enum.reduce(assistants, %{}, &sum_usage/2)
        last = List.last(assistants)

        {:ok,
         %Result{
           assistant_text: assistant_text(last),
           input_tokens: Map.get(usage, :input),
           output_tokens: Map.get(usage, :output),
           cached_input_tokens: Map.get(usage, :cache_read),
           cache_write_tokens: Map.get(usage, :cache_write),
           model_resolved: string_or_nil(last && last["model"]),
           provider: string_or_nil(last && last["provider"]),
           raw: %{"messages" => messages}
         }}

      _ ->
        {:error, {:pi_unexpected_json, summarize(events)}}
    end
  end

  # pi reports `input` net of the cached prefix and `cacheRead` beside it, which
  # is the same split the ledger already stores for jcode. A counter the
  # provider never reported stays nil rather than collapsing to zero.
  defp sum_usage(%{"usage" => usage}, acc) when is_map(usage) do
    acc
    |> add(:input, usage["input"])
    |> add(:output, usage["output"])
    |> add(:cache_read, usage["cacheRead"])
    |> add(:cache_write, usage["cacheWrite"])
  end

  defp sum_usage(_message, acc), do: acc

  defp add(acc, key, value) when is_integer(value) and value >= 0,
    do: Map.update(acc, key, value, &(&1 + value))

  defp add(acc, _key, _value), do: acc

  defp assistant_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text" and is_binary(&1["text"])))
    |> Enum.map_join("", & &1["text"])
  end

  defp assistant_text(_), do: ""

  defp launch_plan!(spec) do
    {:ok, plan} = launch_plan(spec)
    plan
  end

  defp validate_invocation(%Invocation{instruction: instruction})
       when is_binary(instruction) and instruction != "",
       do: :ok

  defp validate_invocation(_), do: {:error, :invalid_invocation}

  defp valid_path?(value, prefix),
    do: valid_absolute_path?(value) and String.starts_with?(Path.expand(value), prefix)

  defp valid_absolute_path?(value),
    do: is_binary(value) and Path.type(value) == :absolute and not String.contains?(value, <<0>>)

  defp positive_timeout?(value),
    do: is_integer(value) and value > 0 and value <= 24 * 60 * 60 * 1_000

  defp valid_model?(nil), do: true

  defp valid_model?(value),
    do:
      is_binary(value) and value != "" and not String.starts_with?(value, "-") and
        String.valid?(value) and not String.contains?(value, <<0>>)

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_), do: nil
  defp summarize(value) when is_binary(value), do: String.slice(value, 0, 4_096)
  defp summarize(value), do: value |> inspect() |> String.slice(0, 4_096)
end
