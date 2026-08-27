defmodule Omashiki.Harness.CliJson do
  @moduledoc """
  Shared CLI/JSON harness helpers extracted from the exec-and-parse-stdout adapters.

  Covers the 19 functions common to `jcode`, `pi`, `codex`, and `claude_code`:
  compose, credential, gateway_base_url, launch_plan!, positive_timeout?,
  prompt_for, string_or_nil, summarize, valid_absolute_path?, validate_invocation,
  valid_model?, valid_path?, plus shared invoke/prepare scaffolding and exec-output
  decoding wrappers.

  **Decode shape** and **usage key mapping** stay in each adapter's
  `decode_output/1` and `normalize_result/1`. HTTP transports (`open_code_http`)
  and host-side credential checks (`claude_code`, `codex`) are out of scope here.
  """

  alias Omashiki.Credentials.Credential
  alias Omashiki.Harness.{Context, Invocation, LaunchPlan}
  alias Omashiki.Plugin.Preset
  alias Omashiki.Jobs.Job
  alias Omashiki.Runtime.Capability
  alias Omashiki.Runtime.Claims

  @doc false
  def invoke(
        %Invocation{} = invocation,
        %Context{capability: %Capability{} = capability} = context,
        default_options,
        cli_argv,
        decode_output,
        normalize_result
      )
      when is_map(default_options) and is_function(cli_argv, 1) and is_function(decode_output, 1) and
             is_function(normalize_result, 1) do
    options = Map.merge(default_options, context.profile.options)

    with :ok <- validate_invocation(invocation),
         {:ok, output} <- Capability.exec(capability, cli_argv.(options), options["timeout_ms"]),
         {:ok, decoded} <- decode_output.(output),
         {:ok, result} <- normalize_result.(decoded) do
      {:ok, result}
    end
  end

  @doc false
  def prepare_gateway(
        %Preset{} = spec,
        %Context{} = context,
        default_options,
        launch_plan,
        secret_env
      )
      when is_map(default_options) and is_function(launch_plan, 1) and is_function(secret_env, 3) do
    options = Map.merge(default_options, spec.options)

    with %Credential{} = credential <- credential(context),
         %Job{} = job <- context.job,
         {:ok, gateway_token} <- Claims.issue("gateway", job, %{credential: credential.name}),
         {:ok, prompt} <- prompt_for(job) do
      plan = launch_plan!(spec, launch_plan)

      {:ok,
       %{
         plan
         | secret: %{"target" => options["invocation_path"], "contents" => prompt},
           environment: plan.environment ++ secret_env.(credential, gateway_token, context)
       }}
    else
      nil -> {:error, :runtime_job_required}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def launch_plan!(%Preset{} = spec, launch_plan) when is_function(launch_plan, 1) do
    {:ok, %LaunchPlan{} = plan} = launch_plan.(spec)
    plan
  end

  @doc false
  def decode_exec_output(output, prefix, decode_stdout)
      when is_atom(prefix) and is_function(decode_stdout, 1) do
    case output do
      %{exit_code: 0, stdout: stdout} when is_binary(stdout) ->
        decode_stdout.(stdout)

      %{"exit_code" => 0, "stdout" => stdout} ->
        decode_exec_output(%{exit_code: 0, stdout: stdout}, prefix, decode_stdout)

      %{exit_code: code, stdout: stdout} ->
        {:error, {exit_error(prefix), code, summarize(stdout)}}

      %{"exit_code" => code, "stdout" => stdout} ->
        decode_exec_output(%{exit_code: code, stdout: stdout}, prefix, decode_stdout)

      other ->
        {:error, {invalid_exec_error(prefix), inspect(other)}}
    end
  end

  @doc false
  def decode_trimmed_json(stdout) when is_binary(stdout) do
    trimmed = String.trim(stdout)

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

  @doc false
  def credential(%Context{credential: %Credential{} = credential}), do: credential
  def credential(_), do: nil

  @doc false
  def gateway_base_url(%Context{host_base_url: base}) when is_binary(base),
    do: String.trim_trailing(base, "/") <> "/api/v1/gateway/v1"

  def gateway_base_url(_), do: Omashiki.Gateway.openai_base_url()

  @doc false
  def prompt_for(%Job{payload: payload}) when is_map(payload), do: compose(payload)
  def prompt_for(%{payload: payload}) when is_map(payload), do: compose(payload)
  def prompt_for(%{"payload" => payload}) when is_map(payload), do: compose(payload)
  def prompt_for(_), do: {:error, :runtime_job_payload_required}

  @doc false
  def compose(payload) do
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

  @doc false
  def invocation_payload(%Job{payload: payload}) when is_map(payload), do: {:ok, payload}
  def invocation_payload(%{payload: payload}) when is_map(payload), do: {:ok, payload}
  def invocation_payload(%{"payload" => payload}) when is_map(payload), do: {:ok, payload}
  def invocation_payload(_), do: {:error, :runtime_job_payload_required}

  @doc false
  def validate_invocation(%Invocation{instruction: instruction})
      when is_binary(instruction) and instruction != "",
      do: :ok

  def validate_invocation(_), do: {:error, :invalid_invocation}

  @doc false
  def validate_options_map(options) when is_map(options), do: :ok
  def validate_options_map(_), do: {:error, :options_must_be_a_map}

  @doc false
  def valid_path?(value, prefix),
    do: valid_absolute_path?(value) and String.starts_with?(Path.expand(value), prefix)

  @doc false
  def valid_absolute_path?(value),
    do: is_binary(value) and Path.type(value) == :absolute and not String.contains?(value, <<0>>)

  @doc false
  def positive_timeout?(value),
    do: is_integer(value) and value > 0 and value <= 24 * 60 * 60 * 1_000

  @doc false
  def valid_model?(nil), do: true

  def valid_model?(value),
    do:
      is_binary(value) and value != "" and not String.starts_with?(value, "-") and
        String.valid?(value) and not String.contains?(value, <<0>>)

  @doc false
  def string_or_nil(value) when is_binary(value) and value != "", do: value
  def string_or_nil(_), do: nil

  @doc false
  def integer_or_nil(value) when is_integer(value) and value >= 0, do: value
  def integer_or_nil(_), do: nil

  @doc false
  def summarize(value) when is_binary(value), do: String.slice(value, 0, 4_096)
  def summarize(value), do: value |> inspect() |> String.slice(0, 4_096)

  defp exit_error(:jcode), do: :jcode_exit
  defp exit_error(:pi), do: :pi_exit
  defp exit_error(:codex), do: :codex_exit
  defp exit_error(:claude), do: :claude_exit
  defp exit_error(prefix), do: :"#{prefix}_exit"

  defp invalid_exec_error(:jcode), do: :jcode_invalid_exec_result
  defp invalid_exec_error(:pi), do: :pi_invalid_exec_result
  defp invalid_exec_error(:codex), do: :codex_invalid_exec_result
  defp invalid_exec_error(:claude), do: :claude_invalid_exec_result
  defp invalid_exec_error(prefix), do: :"#{prefix}_invalid_exec_result"
end
