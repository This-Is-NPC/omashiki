defmodule Omashiki.Harness.OpenCode do
  @moduledoc "OpenCode implementation of the neutral plugin contract."

  @behaviour Omashiki.Harness.Adapter

  alias Omashiki.Credentials.Credential
  alias Omashiki.Harness.{Context, Invocation, LaunchPlan, Result}
  alias Omashiki.Plugin.Preset
  alias Omashiki.Jobs.Job
  alias Omashiki.Runtime.Claims
  alias Omashiki.Runtime.Capability

  @config_path "/run/omashiki/harness/opencode.json"
  @auth_path "/run/omashiki/harness/auth.json"
  @gateway_auth_path "/run/secrets/opencode-auth.json"
  @default_options %{
    "config_path" => @config_path,
    "auth_path" => @auth_path,
    "gateway_auth_path" => @gateway_auth_path,
    "internal_port" => 4096,
    "readiness_path" => "/doc",
    "readiness_timeout_ms" => 60_000
  }
  @option_keys Map.keys(@default_options)

  def config_path, do: @config_path
  def auth_path, do: @auth_path
  def gateway_auth_path, do: @gateway_auth_path

  @impl true
  def validate_options(options) when is_map(options) do
    unknown = Map.keys(options) -- @option_keys

    cond do
      unknown != [] ->
        {:error, {:unknown_options, Enum.sort(unknown)}}

      not positive_int?(Map.get(options, "internal_port", 4096)) ->
        {:error, :invalid_internal_port}

      not positive_int?(Map.get(options, "readiness_timeout_ms", 60_000)) ->
        {:error, :invalid_readiness_timeout}

      not nonempty_string?(Map.get(options, "readiness_path", "/doc")) ->
        {:error, :invalid_readiness_path}

      true ->
        :ok
    end
  end

  def validate_options(_), do: {:error, :options_must_be_a_map}

  @impl true
  def launch_plan(%Preset{runtime: runtime, options: options}) do
    options = Map.merge(@default_options, options)
    port = options["internal_port"]

    {:ok,
     %LaunchPlan{
       runtime: runtime,
       transport: %{
         "kind" => "http",
         "port" => port,
         "port_environment" => ["OPENCODE_PORT=${PORT}"]
       },
       startup: nil,
       readiness: %{
         "kind" => "http",
         "path" => options["readiness_path"],
         "timeout_ms" => options["readiness_timeout_ms"]
       },
       secret: %{"target" => options["auth_path"]},
       environment: []
     }}
  end

  @impl true
  def prepare(%Preset{} = spec, %Context{} = context) do
    options = Map.merge(@default_options, spec.options)
    environment = context.environment || %{}

    case context.credential do
      %Credential{} = credential ->
        prepare_gateway(spec, context, credential, options, environment)

      nil ->
        prepare_host_auth(spec, context, options)

      credential ->
        prepare_gateway(spec, context, credential_from_map(credential), options, environment)
    end
  end

  @impl true
  def invoke(%Invocation{} = invocation, %Context{} = context) do
    credential = context.credential || credential_from_environment(context.environment)
    llm_egress = context.llm_egress || :engine
    payload = message_payload(invocation)
    payload = if credential, do: put_model(payload, credential, llm_egress), else: payload

    with %Capability{} = capability <- context.capability,
         {:ok, session} <- Omashiki.Harness.OpenCode.Http.start_session(capability),
         result <- Omashiki.Harness.OpenCode.Http.send_turn(capability, session, payload) do
      _ = Omashiki.Harness.OpenCode.Http.finish(capability, session)
      result(result)
    else
      _ -> {:error, :harness_endpoint_unavailable}
    end
  end

  defp prepare_gateway(spec, context, %Credential{} = credential, options, environment) do
    with %Job{} = job <- context.job,
         {:ok, gateway_token} <- Claims.issue("gateway", job, %{credential: credential.name}),
         {:ok, tools_token} <- Claims.issue("tools", job, %{}) do
      config = gateway_config(credential, gateway_token, tools_token, environment, context)
      plan = launch_plan!(spec)

      {:ok,
       %{
         plan
         | secret: %{
             "target" => options["gateway_auth_path"],
             "contents" =>
               Jason.encode!(%{"gateway" => %{"type" => "api", "key" => gateway_token}})
           },
           environment: [
             "OPENCODE_CONFIG_CONTENT=#{config}",
             "OPENCODE_AUTH_PATH=#{options["gateway_auth_path"]}",
             "HOME=/tmp/agent-home"
           ]
       }
       |> put_egress(:gateway)}
    else
      nil -> {:error, :runtime_job_required}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_host_auth(spec, context, options) do
    with :ok <-
           require_host_file(
             context.runtime_mounts,
             options["config_path"],
             :harness_config_unavailable
           ),
         :ok <-
           require_host_file(
             context.runtime_mounts,
             options["auth_path"],
             :harness_auth_unavailable
           ) do
      plan = launch_plan!(spec)

      {:ok,
       %{
         plan
         | secret: nil,
           environment: [
             "OPENCODE_CONFIG_CONTENT=#{Jason.encode!(%{"$schema" => "https://opencode.ai/config.json"})}",
             "OPENCODE_AUTH_PATH=#{options["auth_path"]}",
             "OPENCODE_CONFIG_PATH=#{options["config_path"]}",
             "HOME=/tmp/agent-home"
           ]
       }
       |> put_egress(:engine)}
    end
  end

  defp launch_plan!(spec) do
    {:ok, plan} = launch_plan(spec)
    plan
  end

  defp put_egress(%LaunchPlan{} = plan, egress), do: Map.put(plan, :llm_egress, egress)

  defp gateway_config(credential, gateway_token, tools_token, env_snapshot, context) do
    model = credential.model

    base_url =
      case context.host_base_url do
        base when is_binary(base) -> String.trim_trailing(base, "/") <> "/api/v1/gateway/v1"
        _ -> Omashiki.Gateway.openai_base_url()
      end

    %{
      "$schema" => "https://opencode.ai/config.json",
      "model" => "gateway/#{model}",
      "provider" => %{
        "gateway" => %{
          "npm" => "@ai-sdk/openai-compatible",
          "name" => "gateway",
          "options" => %{"baseURL" => base_url, "apiKey" => gateway_token},
          "models" => %{model => %{}}
        }
      }
    }
    |> merge_mcp(env_snapshot, tools_token, context.profile, context.host_base_url)
    |> Jason.encode!()
  end

  defp merge_mcp(config, env_snapshot, token, profile, base_url) do
    servers = Map.get(env_snapshot, "mcp_servers", %{})

    if is_map(servers) and map_size(servers) > 0 do
      Map.merge(
        config,
        Omashiki.Tools.McpConfig.render(env_snapshot, profile, %{token: token, base_url: base_url})
      )
    else
      config
    end
  end

  defp message_payload(%Invocation{instruction: instruction, context: nil}),
    do: %{parts: [%{type: "text", text: instruction}]}

  defp message_payload(%Invocation{instruction: instruction, context: context}) do
    %{parts: [%{type: "text", text: instruction <> "\n\nContext:\n" <> Jason.encode!(context)}]}
  end

  defp put_model(payload, %Credential{} = credential, :gateway),
    do: Map.put(payload, :model, %{providerID: "gateway", modelID: credential.model})

  defp put_model(payload, %Credential{} = credential, _),
    do: Map.put(payload, :model, %{providerID: credential.provider, modelID: credential.model})

  defp result({:ok, %Result{} = value}), do: {:ok, value}
  defp result({:ok, value}) when is_map(value), do: {:ok, Result.from_map(value)}
  defp result(other), do: other

  defp credential_from_environment(%{"credentials" => [credential | _]}),
    do: credential_from_map(credential)

  defp credential_from_environment(_), do: nil

  defp credential_from_map(%Credential{} = credential), do: credential

  defp credential_from_map(%{} = credential) do
    struct(
      Credential,
      Map.take(credential, [:name, :provider, :model, :base_url, :fallback_chain, :model_aliases])
      |> Map.merge(
        Map.take(credential, [
          "name",
          "provider",
          "model",
          "base_url",
          "fallback_chain",
          "model_aliases"
        ])
      )
      |> Map.new(fn {key, value} ->
        {if(is_binary(key), do: String.to_existing_atom(key), else: key), value}
      end)
    )
  rescue
    ArgumentError -> nil
  end

  defp require_host_file(mounts, target, reason) do
    case Enum.find(mounts || %{}, fn
           {_source, destination, _read_only} -> destination == target
           {_source, destination} -> destination == target
         end) do
      {source, ^target, _read_only} ->
        if File.regular?(expand_host_path(source)), do: :ok, else: {:error, {reason, source}}

      {source, ^target} ->
        if File.regular?(expand_host_path(source)), do: :ok, else: {:error, {reason, source}}

      nil ->
        {:error, {reason, target}}
    end
  end

  defp expand_host_path("~/" <> rest), do: Path.join(System.user_home!(), rest)
  defp expand_host_path("~"), do: System.user_home!()
  defp expand_host_path(path), do: path
  defp positive_int?(value), do: is_integer(value) and value > 0
  defp nonempty_string?(value), do: is_binary(value) and value != ""
end
