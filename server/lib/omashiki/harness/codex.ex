defmodule Omashiki.Harness.Codex do
  @moduledoc "OpenAI Codex CLI 0.149.1 implementation of the neutral harness contract."

  @behaviour Omashiki.Harness.Adapter

  alias Omashiki.Harness.{Context, Invocation, LaunchPlan, Result, Spec}
  alias Omashiki.Jobs.Job
  alias Omashiki.Runtime.Capability

  @credentials_path "/run/omashiki/state/codex-auth.json"
  @invocation_path "/tmp/omashiki-codex-invocation.json"
  @runner_path "/usr/local/bin/omashiki-codex-runner"
  @codex_home "/tmp/agent-home/.codex"
  @default_timeout_ms 900_000
  @default_options %{
    "credentials_path" => @credentials_path,
    "invocation_path" => @invocation_path,
    "runner_path" => @runner_path,
    "timeout_ms" => @default_timeout_ms,
    "model" => nil,
    "reasoning_effort" => nil,
    "web_search" => false
  }

  # Codex expresses effort through `model_reasoning_effort`, not through a
  # model slug suffix. `gpt-5.6-luna:low` is two settings, not one model name.
  @reasoning_efforts ~w(minimal low medium high)
  @option_keys Map.keys(@default_options)

  def credentials_path, do: @credentials_path
  def invocation_path, do: @invocation_path
  def runner_path, do: @runner_path
  def codex_home, do: @codex_home

  @impl true
  def validate_options(options) when is_map(options) do
    unknown = Map.keys(options) -- @option_keys
    options = Map.merge(@default_options, options)

    cond do
      unknown != [] ->
        {:error, {:unknown_options, Enum.sort(unknown)}}

      not valid_path?(options["credentials_path"], "/run/omashiki/state/") ->
        {:error, :invalid_credentials_path}

      not valid_path?(options["invocation_path"], "/tmp/") ->
        {:error, :invalid_invocation_path}

      not valid_absolute_path?(options["runner_path"]) ->
        {:error, :invalid_runner_path}

      not positive_timeout?(options["timeout_ms"]) ->
        {:error, :invalid_timeout}

      not valid_model?(options["model"]) ->
        {:error, :invalid_model}

      not valid_reasoning_effort?(options["reasoning_effort"]) ->
        {:error, :invalid_reasoning_effort}

      not is_boolean(options["web_search"]) ->
        {:error, :invalid_web_search}

      true ->
        :ok
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
         "argv" => ["/usr/local/bin/codex", "login", "status"],
         "timeout_ms" => 10_000
       },
       secret: nil,
       environment: [
         "HOME=/tmp/agent-home",
         "CODEX_HOME=#{@codex_home}",
         "CODEX_CREDENTIALS_PATH=#{options["credentials_path"]}"
       ],
       llm_egress: :engine
     }}
  end

  @impl true
  def prepare(%Spec{} = spec, %Context{} = context) do
    options = Map.merge(@default_options, spec.options)

    with :ok <- require_mount(context.runtime_mounts, options["credentials_path"]),
         {:ok, payload} <- invocation_payload(context.job) do
      plan = launch_plan!(spec)

      {:ok,
       %{
         plan
         | secret: %{
             "target" => options["invocation_path"],
             "contents" => Jason.encode!(payload)
           }
       }}
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

  defp cli_argv(options) do
    [options["runner_path"], options["invocation_path"]] ++
      if(options["web_search"], do: ["--web-search"], else: []) ++
      if(options["model"], do: ["--model", options["model"]], else: []) ++
      if(options["reasoning_effort"],
        do: ["--reasoning-effort", options["reasoning_effort"]],
        else: []
      )
  end

  defp decode_output(%{exit_code: 0, stdout: stdout}) when is_binary(stdout) do
    case decode_json_result(stdout) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _} -> {:error, :codex_json_object_required}
      {:error, _} -> {:error, {:codex_non_json_output, summarize(stdout)}}
    end
  end

  defp decode_output(%{"exit_code" => 0, "stdout" => stdout}),
    do: decode_output(%{exit_code: 0, stdout: stdout})

  defp decode_output(%{exit_code: code, stdout: stdout}),
    do: {:error, {:codex_exit, code, summarize(stdout)}}

  defp decode_output(%{"exit_code" => code, "stdout" => stdout}),
    do: decode_output(%{exit_code: code, stdout: stdout})

  defp decode_output(other), do: {:error, {:codex_invalid_exec_result, inspect(other)}}

  defp decode_json_result(output) do
    trimmed = String.trim(output)

    case Jason.decode(trimmed) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, original_error} ->
        trimmed
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Enum.find_value({:error, original_error}, fn line ->
          case Jason.decode(line) do
            {:ok, decoded} -> {:ok, decoded}
            {:error, _} -> nil
          end
        end)
    end
  end

  # Codex only reports usage on `turn.completed`; when the counter is absent the
  # field stays nil rather than collapsing into a fictional zero.
  defp normalize_result(%{"type" => "result", "is_error" => false} = decoded) do
    usage = Map.get(decoded, "usage")
    usage = if is_map(usage), do: usage, else: %{}

    {:ok,
     %Result{
       assistant_text: Map.get(decoded, "result", ""),
       input_tokens: integer_or_nil(usage["input_tokens"]),
       output_tokens: integer_or_nil(usage["output_tokens"]),
       cached_input_tokens: integer_or_nil(usage["cached_input_tokens"]),
       cache_write_tokens: integer_or_nil(usage["cache_write_input_tokens"]),
       model_resolved: model_or_nil(Map.get(decoded, "model")),
       provider: "openai",
       raw: decoded
     }}
  end

  defp normalize_result(%{"type" => "result", "is_error" => true} = decoded),
    do: {:error, {:codex_result_error, summarize(Map.get(decoded, "result", decoded))}}

  defp normalize_result(decoded), do: {:error, {:codex_unexpected_json, summarize(decoded)}}

  defp launch_plan!(spec) do
    {:ok, plan} = launch_plan(spec)
    plan
  end

  defp invocation_payload(%Job{payload: payload}) when is_map(payload), do: {:ok, payload}
  defp invocation_payload(%{payload: payload}) when is_map(payload), do: {:ok, payload}
  defp invocation_payload(%{"payload" => payload}) when is_map(payload), do: {:ok, payload}
  defp invocation_payload(_), do: {:error, :runtime_job_payload_required}

  defp validate_invocation(%Invocation{instruction: instruction})
       when is_binary(instruction) and instruction != "",
       do: :ok

  defp validate_invocation(_), do: {:error, :invalid_invocation}

  defp require_mount(mounts, target) do
    case Enum.find(mounts || %{}, fn
           {_source, destination, _read_only} -> destination == target
           {_source, destination} -> destination == target
           _ -> false
         end) do
      {source, ^target, false} when is_binary(source) ->
        if File.regular?(expand_host_path(source)),
          do: :ok,
          else: {:error, {:codex_credentials_unavailable, source}}

      {source, ^target, _read_only} when is_binary(source) ->
        {:error, {:codex_credentials_mount_must_be_writable, source}}

      {source, ^target} when is_binary(source) ->
        {:error, {:codex_credentials_mount_must_be_writable, source}}

      nil ->
        {:error, {:codex_credentials_mount_missing, target}}
    end
  end

  defp expand_host_path("~/" <> rest), do: Path.join(System.user_home!(), rest)
  defp expand_host_path("~"), do: System.user_home!()
  defp expand_host_path(path), do: path

  defp valid_path?(value, prefix),
    do: valid_absolute_path?(value) and String.starts_with?(Path.expand(value), prefix)

  defp valid_absolute_path?(value),
    do: is_binary(value) and Path.type(value) == :absolute and not String.contains?(value, <<0>>)

  defp positive_timeout?(value),
    do: is_integer(value) and value > 0 and value <= 24 * 60 * 60 * 1_000

  defp valid_reasoning_effort?(nil), do: true
  defp valid_reasoning_effort?(value), do: value in @reasoning_efforts

  defp valid_model?(nil), do: true

  defp valid_model?(value),
    do:
      is_binary(value) and value != "" and not String.starts_with?(value, "-") and
        String.valid?(value) and not String.contains?(value, <<0>>)

  defp model_or_nil(value) when is_binary(value) and value != "", do: value
  defp model_or_nil(_), do: nil

  defp integer_or_nil(value) when is_integer(value) and value >= 0, do: value
  defp integer_or_nil(_), do: nil
  defp summarize(value) when is_binary(value), do: String.slice(value, 0, 4_096)
  defp summarize(value), do: value |> inspect() |> String.slice(0, 4_096)
end
