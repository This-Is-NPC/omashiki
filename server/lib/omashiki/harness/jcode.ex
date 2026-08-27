defmodule Omashiki.Harness.Jcode do
  @moduledoc """
  jcode 0.81 implementation of the neutral harness contract.

  jcode is a single static binary that reaches any OpenAI-compatible endpoint
  through a named provider profile, so it runs entirely on the gateway path:
  the container is handed a job-bound token and a loopback base URL, never a
  provider key. That is also why this adapter has no host-auth branch — the
  subscription routes jcode supports are covered by the other presets.
  """

  @behaviour Omashiki.Harness.Adapter

  alias Omashiki.Harness.{CliJson, Context, Invocation, LaunchPlan, Result}
  alias Omashiki.Plugin.Preset
  alias Omashiki.Runtime.Capability

  @invocation_path "/tmp/omashiki-jcode-invocation.txt"
  @runner_path "/usr/local/bin/omashiki-jcode-runner"
  @jcode_home "/tmp/agent-home/.jcode"
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
  def jcode_home, do: @jcode_home

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
  def launch_plan(%Preset{runtime: runtime, options: raw_options}) do
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
         "JCODE_HOME=#{@jcode_home}"
       ],
       llm_egress: :gateway
     }}
  end

  @impl true
  def prepare(%Preset{} = spec, %Context{} = context) do
    CliJson.prepare_gateway(spec, context, @default_options, &launch_plan/1, fn
      credential, gateway_token, ctx ->
        [
          "JCODE_GATEWAY_BASE_URL=#{CliJson.gateway_base_url(ctx)}",
          "JCODE_GATEWAY_MODEL=#{credential.model}",
          "JCODE_GATEWAY_TOKEN=#{gateway_token}"
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

  defp decode_output(output) do
    CliJson.decode_exec_output(output, :jcode, fn stdout ->
      case Jason.decode(String.trim(stdout)) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _} -> {:error, :jcode_json_object_required}
        {:error, _} -> {:error, {:jcode_non_json_output, CliJson.summarize(stdout)}}
      end
    end)
  end

  # jcode reports `cache_creation_input_tokens: null` when the provider does not
  # bill cache writes; that absence stays nil rather than collapsing to zero.
  defp normalize_result(%{"text" => text} = decoded) when is_binary(text) do
    usage = if is_map(decoded["usage"]), do: decoded["usage"], else: %{}

    {:ok,
     %Result{
       assistant_text: text,
       input_tokens: CliJson.integer_or_nil(usage["input_tokens"]),
       output_tokens: CliJson.integer_or_nil(usage["output_tokens"]),
       cached_input_tokens: CliJson.integer_or_nil(usage["cache_read_input_tokens"]),
       cache_write_tokens: CliJson.integer_or_nil(usage["cache_creation_input_tokens"]),
       model_resolved: CliJson.string_or_nil(decoded["model"]),
       provider: CliJson.string_or_nil(decoded["provider"]),
       raw: decoded
     }}
  end

  defp normalize_result(decoded),
    do: {:error, {:jcode_unexpected_json, CliJson.summarize(decoded)}}
end
