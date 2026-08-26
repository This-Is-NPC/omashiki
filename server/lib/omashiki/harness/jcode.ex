defmodule Omashiki.Harness.Jcode do
  @moduledoc """
  jcode 0.81 implementation of the neutral harness contract.

  jcode is a single static binary that reaches any OpenAI-compatible endpoint
  through a named provider profile, so it runs entirely on the gateway path:
  the container is handed a job-bound token and a loopback base URL, never a
  provider key. That is also why this adapter has no host-auth branch — the
  subscription routes jcode supports are covered by the other harnesses.
  """

  @behaviour Omashiki.Harness.Adapter

  alias Omashiki.Credentials.Credential
  alias Omashiki.Harness.{Context, Invocation, LaunchPlan, Result, Spec}
  alias Omashiki.Jobs.Job
  alias Omashiki.Runtime.Capability
  alias Omashiki.Runtime.Claims

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
         "JCODE_HOME=#{@jcode_home}"
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
                 "JCODE_GATEWAY_BASE_URL=#{gateway_base_url(context)}",
                 "JCODE_GATEWAY_MODEL=#{credential.model}",
                 "JCODE_GATEWAY_TOKEN=#{gateway_token}"
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
         {:ok, decoded} <- decode_output(output),
         {:ok, result} <- normalize_result(decoded) do
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

  defp decode_output(%{exit_code: 0, stdout: stdout}) when is_binary(stdout) do
    case Jason.decode(String.trim(stdout)) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _} -> {:error, :jcode_json_object_required}
      {:error, _} -> {:error, {:jcode_non_json_output, summarize(stdout)}}
    end
  end

  defp decode_output(%{"exit_code" => 0, "stdout" => stdout}),
    do: decode_output(%{exit_code: 0, stdout: stdout})

  defp decode_output(%{exit_code: code, stdout: stdout}),
    do: {:error, {:jcode_exit, code, summarize(stdout)}}

  defp decode_output(%{"exit_code" => code, "stdout" => stdout}),
    do: decode_output(%{exit_code: code, stdout: stdout})

  defp decode_output(other), do: {:error, {:jcode_invalid_exec_result, inspect(other)}}

  # jcode reports `cache_creation_input_tokens: null` when the provider does not
  # bill cache writes; that absence stays nil rather than collapsing to zero.
  defp normalize_result(%{"text" => text} = decoded) when is_binary(text) do
    usage = if is_map(decoded["usage"]), do: decoded["usage"], else: %{}

    {:ok,
     %Result{
       assistant_text: text,
       input_tokens: integer_or_nil(usage["input_tokens"]),
       output_tokens: integer_or_nil(usage["output_tokens"]),
       cached_input_tokens: integer_or_nil(usage["cache_read_input_tokens"]),
       cache_write_tokens: integer_or_nil(usage["cache_creation_input_tokens"]),
       model_resolved: string_or_nil(decoded["model"]),
       provider: string_or_nil(decoded["provider"]),
       raw: decoded
     }}
  end

  defp normalize_result(decoded), do: {:error, {:jcode_unexpected_json, summarize(decoded)}}

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
  defp integer_or_nil(value) when is_integer(value) and value >= 0, do: value
  defp integer_or_nil(_), do: nil
  defp summarize(value) when is_binary(value), do: String.slice(value, 0, 4_096)
  defp summarize(value), do: value |> inspect() |> String.slice(0, 4_096)
end
