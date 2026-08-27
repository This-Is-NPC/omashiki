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

  alias Omashiki.Harness.{CliJson, Context, Invocation, LaunchPlan, Result, Spec}
  alias Omashiki.Runtime.Capability

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
      not CliJson.valid_path?(options["invocation_path"], "/tmp/") -> {:error, :invalid_invocation_path}
      not CliJson.valid_absolute_path?(options["runner_path"]) -> {:error, :invalid_runner_path}
      not CliJson.positive_timeout?(options["timeout_ms"]) -> {:error, :invalid_timeout}
      not CliJson.valid_model?(options["model"]) -> {:error, :invalid_model}
      true -> :ok
    end
  end

  def validate_options(_), do: CliJson.validate_options_map(nil)

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
    CliJson.prepare_gateway(spec, context, @default_options, &launch_plan/1, fn
      credential, gateway_token, ctx ->
        [
          "PI_GATEWAY_BASE_URL=#{CliJson.gateway_base_url(ctx)}",
          "PI_GATEWAY_MODEL=#{credential.model}",
          "PI_GATEWAY_TOKEN=#{gateway_token}"
        ]
    end)
  end

  @impl true
  def invoke(%Invocation{} = invocation, %Context{capability: %Capability{}} = context) do
    CliJson.invoke(
      invocation,
      context,
      @default_options,
      &cli_argv/1,
      &decode_output/1,
      &normalize_result/1
    )
  end

  def invoke(%Invocation{}, %Context{}), do: {:error, :runtime_capability_unavailable}

  defp cli_argv(options) do
    [options["runner_path"], options["invocation_path"]] ++
      if(options["model"], do: ["--model", options["model"]], else: [])
  end

  # pi writes one JSON event per line and interleaves nothing else on stdout,
  # but a non-JSON line is tolerated rather than fatal: a stray warning must
  # not discard a run that otherwise completed.
  defp decode_output(output) do
    CliJson.decode_exec_output(output, :pi, fn stdout ->
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
        [] -> {:error, {:pi_non_json_output, CliJson.summarize(stdout)}}
        events -> {:ok, events}
      end
    end)
  end

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
           model_resolved: CliJson.string_or_nil(last && last["model"]),
           provider: CliJson.string_or_nil(last && last["provider"]),
           raw: %{"messages" => messages}
         }}

      _ ->
        {:error, {:pi_unexpected_json, CliJson.summarize(events)}}
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
end
