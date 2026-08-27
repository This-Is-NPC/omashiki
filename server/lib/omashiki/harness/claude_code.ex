defmodule Omashiki.Harness.ClaudeCode do
  @moduledoc "Claude Code 2.1.240 implementation of the neutral harness contract."

  @behaviour Omashiki.Harness.Adapter

  alias Omashiki.Harness.{CliJson, Context, Invocation, LaunchPlan, Result}
  alias Omashiki.Plugin.Preset
  alias Omashiki.Runtime.Capability

  @credentials_path "/run/omashiki/state/claude-credentials.json"
  @invocation_path "/tmp/omashiki-claude-invocation.json"
  @runner_path "/usr/local/bin/omashiki-claude-runner"
  @default_timeout_ms 900_000
  @required_tools ["Read", "Edit", "Write", "Glob", "Grep", "Bash(git *)", "Bash(python3 *)"]
  @default_options %{
    "credentials_path" => @credentials_path,
    "invocation_path" => @invocation_path,
    "runner_path" => @runner_path,
    "timeout_ms" => @default_timeout_ms,
    "model" => nil,
    "allowed_tools" => @required_tools
  }
  @option_keys Map.keys(@default_options)

  def credentials_path, do: @credentials_path
  def invocation_path, do: @invocation_path
  def runner_path, do: @runner_path
  def required_tools, do: @required_tools

  @impl true
  def validate_options(options) when is_map(options) do
    unknown = Map.keys(options) -- @option_keys
    options = Map.merge(@default_options, options)

    cond do
      unknown != [] ->
        {:error, {:unknown_options, Enum.sort(unknown)}}

      not CliJson.valid_path?(options["credentials_path"], "/run/omashiki/state/") ->
        {:error, :invalid_credentials_path}

      not CliJson.valid_path?(options["invocation_path"], "/tmp/") ->
        {:error, :invalid_invocation_path}

      not CliJson.valid_absolute_path?(options["runner_path"]) ->
        {:error, :invalid_runner_path}

      not CliJson.positive_timeout?(options["timeout_ms"]) ->
        {:error, :invalid_timeout}

      not CliJson.valid_model?(options["model"]) ->
        {:error, :invalid_model}

      not valid_tools?(options["allowed_tools"]) ->
        {:error, :invalid_allowed_tools}

      true ->
        :ok
    end
  end

  def validate_options(_), do: CliJson.validate_options_map(nil)

  @impl true
  def launch_plan(%Preset{runtime: runtime, options: raw_options}) do
    options = Map.merge(@default_options, raw_options)
    argv = cli_argv(options)

    {:ok,
     %LaunchPlan{
       runtime: runtime,
       transport: %{
         "kind" => "cli",
         "argv" => argv,
         "timeout_ms" => options["timeout_ms"]
       },
       startup: nil,
       readiness: %{
         "kind" => "exec",
         "argv" => ["/usr/local/bin/claude", "auth", "status"],
         "timeout_ms" => 10_000
       },
       secret: nil,
       environment: [
         "HOME=/tmp/agent-home",
         "CLAUDE_CREDENTIALS_PATH=#{options["credentials_path"]}"
       ],
       llm_egress: :engine
     }}
  end

  @impl true
  def prepare(%Preset{} = spec, %Context{} = context) do
    options = Map.merge(@default_options, spec.options)

    with :ok <- require_mount(context.runtime_mounts, options["credentials_path"]),
         {:ok, payload} <- CliJson.invocation_payload(context.job) do
      plan = CliJson.launch_plan!(spec, &launch_plan/1)

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
      Enum.flat_map(options["allowed_tools"], &["--allowed-tool", &1]) ++
      if(options["model"], do: ["--model", options["model"]], else: [])
  end

  defp decode_output(output) do
    CliJson.decode_exec_output(output, :claude, fn stdout ->
      case CliJson.decode_trimmed_json(stdout) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _} -> {:error, :claude_json_object_required}
        {:error, _} -> {:error, {:claude_non_json_output, CliJson.summarize(stdout)}}
      end
    end)
  end

  defp normalize_result(%{"type" => "result", "is_error" => false} = decoded) do
    model_usage = Map.get(decoded, "modelUsage", %{})
    usage = Map.get(decoded, "usage") || first_model_usage(model_usage)
    usage = if is_map(usage), do: usage, else: %{}

    {:ok,
     %Result{
       assistant_text: Map.get(decoded, "result", ""),
       input_tokens: CliJson.integer_or_nil(usage["input_tokens"] || usage["inputTokens"]),
       output_tokens: CliJson.integer_or_nil(usage["output_tokens"] || usage["outputTokens"]),
       cached_input_tokens:
         CliJson.integer_or_nil(usage["cache_read_input_tokens"] || usage["cacheReadInputTokens"]),
       cache_write_tokens:
         CliJson.integer_or_nil(usage["cache_creation_input_tokens"] || usage["cacheCreationInputTokens"]),
       model_resolved: Map.get(decoded, "model") || first_model(model_usage),
       provider: "anthropic",
       raw: decoded
     }}
  end

  defp normalize_result(%{"type" => "result", "is_error" => true} = decoded),
    do: {:error, {:claude_result_error, CliJson.summarize(Map.get(decoded, "result", decoded))}}

  defp normalize_result(decoded),
    do: {:error, {:claude_unexpected_json, CliJson.summarize(decoded)}}

  defp first_model(model_usage) when is_map(model_usage),
    do: model_usage |> Map.keys() |> Enum.sort() |> List.first()

  defp first_model(_), do: nil

  defp first_model_usage(model_usage) when is_map(model_usage) do
    case first_model(model_usage) do
      model when is_binary(model) -> Map.get(model_usage, model)
      _ -> nil
    end
  end

  defp first_model_usage(_), do: nil

  # Host-side File.regular?, mount-writability, and ~ expansion — security
  # decisions, not string templating. Stay in this adapter per task 2826.
  defp require_mount(mounts, target) do
    case Enum.find(mounts || %{}, fn
           {_source, destination, _read_only} -> destination == target
           {_source, destination} -> destination == target
           _ -> false
         end) do
      {source, ^target, false} when is_binary(source) ->
        if File.regular?(expand_host_path(source)),
          do: :ok,
          else: {:error, {:claude_credentials_unavailable, source}}

      {source, ^target, _read_only} when is_binary(source) ->
        {:error, {:claude_credentials_mount_must_be_writable, source}}

      {source, ^target} when is_binary(source) ->
        {:error, {:claude_credentials_mount_must_be_writable, source}}

      nil ->
        {:error, {:claude_credentials_mount_missing, target}}
    end
  end

  defp expand_host_path("~/" <> rest), do: Path.join(System.user_home!(), rest)
  defp expand_host_path("~"), do: System.user_home!()
  defp expand_host_path(path), do: path

  defp valid_tools?(tools) when is_list(tools) do
    tools != [] and length(tools) == length(Enum.uniq(tools)) and
      Enum.all?(tools, &(&1 in @required_tools)) and Enum.all?(@required_tools, &(&1 in tools))
  end

  defp valid_tools?(_), do: false
end
