defmodule Omashiki.Plugin.Interpreter do
  @moduledoc "Generic declarative plugin interpreter for `plugins/*.toml`."

  @behaviour Omashiki.Harness.Adapter

  alias Omashiki.Credentials.Credential
  alias Omashiki.Harness.{CliJson, Context, Invocation, LaunchPlan, Result}
  alias Omashiki.Plugin.{Http, Manifest, OptionSchema, Shapes}
  alias Omashiki.Plugin.Preset
  alias Omashiki.Jobs.Job
  alias Omashiki.Runtime.{Capability, Claims}
  alias Omashiki.Runtime.Spec
  alias Omashiki.Runtime.HostCredentials

  @impl true
  def validate_options(%Manifest{} = manifest, options) when is_map(options),
    do: OptionSchema.validate(manifest, options)

  def validate_options(_, _), do: {:error, :options_must_be_a_map}

  @impl true
  def launch_plan(%Preset{
        manifest: %Manifest{} = manifest,
        runtime: %Spec{} = runtime,
        options: raw
      }) do
    options = merged_options(manifest, raw)

    transport =
      case manifest.transport do
        "cli" ->
          %{
            "kind" => "cli",
            "argv" => build_argv(manifest, options),
            "timeout_ms" => options["timeout_ms"]
          }

        "http" ->
          http = manifest.http || %{}

          %{
            "kind" => "http",
            "port" => Map.get(http, "internal_port", 4096),
            "port_environment" => Map.get(http, "port_environment", ["OPENCODE_PORT=${PORT}"])
          }
      end

    readiness =
      case manifest.readiness do
        %{"kind" => "none"} ->
          nil

        %{"kind" => _kind} = r ->
          Map.put(r, "argv", substitute_list(Map.get(r, "argv", []), bindings(options, %{})))
      end

    {:ok,
     %LaunchPlan{
       runtime: runtime,
       transport: transport,
       startup: nil,
       readiness:
         readiness && Map.update!(readiness, "argv", &substitute_list(&1, bindings(options, %{}))),
       secret: secret_plan(manifest, options),
       environment: static_env(manifest, options),
       llm_egress: manifest.llm_egress
     }}
  end

  def launch_plan(_), do: {:error, :manifest_required}

  @impl true
  def prepare(%Preset{manifest: %Manifest{} = manifest} = spec, %Context{} = context) do
    options = merged_options(manifest, spec.options)

    case resolved_prepare(manifest.prepare, context) do
      "gateway_prompt" -> prepare_gateway_prompt(spec, context, manifest, options)
      "invocation_json" -> prepare_invocation_json(spec, context, manifest, options)
      "opencode_gateway" -> prepare_opencode_gateway(spec, context, manifest, options)
      "opencode_host" -> prepare_opencode_host(spec, context, manifest, options)
      "none" -> {:ok, %{launch_plan!(spec) | secret: nil}}
      other -> {:error, {:unsupported_prepare, other}}
    end
  end

  def prepare(_, _), do: {:error, :manifest_required}

  defp resolved_prepare("opencode_host", context) do
    case CliJson.credential(context) do
      %Credential{} -> "opencode_gateway"
      _ -> "opencode_host"
    end
  end

  defp resolved_prepare(kind, _context), do: kind

  @impl true
  def invoke(%Invocation{} = invocation, %Context{capability: %Capability{}} = context) do
    manifest = manifest!(context.profile)

    case manifest.transport do
      "cli" -> invoke_cli(invocation, context, manifest)
      "http" -> invoke_http(invocation, context, manifest)
      other -> {:error, {:unsupported_transport, other}}
    end
  end

  def invoke(%Invocation{}, %Context{}), do: {:error, :runtime_capability_unavailable}

  defp invoke_cli(invocation, context, manifest) do
    options = merged_options(manifest, context.profile.options)
    prefix = String.to_atom(manifest.name)

    CliJson.invoke(
      invocation,
      context,
      options,
      fn opts -> build_argv(manifest, opts) end,
      fn output -> decode_cli_output(output, manifest, prefix) end,
      fn decoded -> Shapes.normalize(manifest.output, decoded) end
    )
  end

  defp invoke_http(invocation, context, manifest) do
    credential = context.credential || credential_from_environment(context.environment)
    llm_egress = context.llm_egress || :engine
    payload = message_payload(invocation)
    payload = put_model(payload, credential, llm_egress, manifest, context)

    with %Capability{} = capability <- context.capability,
         {:ok, session} <- Http.start_session(capability),
         result <- Http.send_turn(capability, session, payload) do
      _ = Http.finish(capability, session)
      normalize_http_result(result)
    else
      _ -> {:error, :harness_endpoint_unavailable}
    end
  end

  defp decode_cli_output(output, manifest, prefix) do
    Shapes.decode_exec_output(output, prefix, fn stdout ->
      case manifest.output["shape"] do
        "jsonl_agent_end" ->
          events =
            stdout
            |> String.split("\n", trim: true)
            |> Enum.flat_map(fn line ->
              case Jason.decode(line) do
                {:ok, event} when is_map(event) -> [event]
                _ -> []
              end
            end)

          if events == [],
            do: {:error, {:non_json_output, CliJson.summarize(stdout)}},
            else: {:ok, events}

        _ ->
          case Jason.decode(String.trim(stdout)) do
            {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
            _ -> CliJson.decode_trimmed_json(stdout)
          end
      end
    end)
  end

  defp prepare_gateway_prompt(spec, context, manifest, options) do
    with %Credential{} = credential <- CliJson.credential(context),
         %Job{} = job <- context.job,
         {:ok, gateway_token} <- Claims.issue("gateway", job, %{credential: credential.name}),
         {:ok, prompt} <- CliJson.prompt_for(job) do
      plan = launch_plan!(spec)
      secret = file_secret(manifest, options, prompt)
      gateway = Map.get(manifest.env, "gateway", %{})

      gateway_bindings =
        bindings(options, %{
          "gateway_base_url" => CliJson.gateway_base_url(context),
          "gateway_token" => gateway_token,
          "gateway_model" => credential.model
        })

      gateway_env =
        Enum.map(gateway, fn {k, v} ->
          "#{k}=#{substitute(v, gateway_bindings)}"
        end)

      {:ok,
       %{
         plan
         | secret: secret,
           environment: plan.environment ++ gateway_env
       }}
    else
      nil -> {:error, :runtime_job_required}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_invocation_json(spec, context, _manifest, options) do
    with :ok <-
           HostCredentials.validate_mount(context.runtime_mounts, options["credentials_path"]),
         {:ok, payload} <- CliJson.invocation_payload(context.job) do
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

  defp prepare_opencode_gateway(spec, context, manifest, _options) do
    with %Credential{} = credential <- CliJson.credential(context),
         %Job{} = job <- context.job,
         {:ok, gateway_token} <- Claims.issue("gateway", job, %{credential: credential.name}),
         {:ok, tools_token} <- Claims.issue("tools", job, %{}) do
      model = profile_option(spec, "model") || credential.model
      config = opencode_gateway_config(model, gateway_token, tools_token, context, spec)
      http = manifest.http || %{}
      plan = launch_plan!(spec)

      {:ok,
       %{
         plan
         | secret: %{
             "target" => Map.get(http, "gateway_auth_path", "/run/secrets/opencode-auth.json"),
             "contents" =>
               Jason.encode!(%{"gateway" => %{"type" => "api", "key" => gateway_token}})
           },
           environment: [
             "OPENCODE_CONFIG_CONTENT=#{config}",
             "OPENCODE_AUTH_PATH=#{Map.get(http, "gateway_auth_path", "/run/secrets/opencode-auth.json")}",
             "HOME=/tmp/agent-home"
           ],
           llm_egress: :gateway
       }}
    else
      nil -> {:error, :runtime_job_required}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_opencode_host(spec, context, _manifest, options) do
    with :ok <- HostCredentials.validate_mount(context.runtime_mounts, options["config_path"]),
         :ok <- HostCredentials.validate_mount(context.runtime_mounts, options["auth_path"]) do
      model = Map.get(spec.options, "model")
      schema = Jason.encode!(%{"$schema" => "https://opencode.ai/config.json"})

      content =
        if is_binary(model) and model != "" do
          Jason.encode!(%{"$schema" => "https://opencode.ai/config.json", "model" => model})
        else
          schema
        end

      plan = launch_plan!(spec)

      {:ok,
       %{
         plan
         | secret: nil,
           environment: [
             "OPENCODE_CONFIG_CONTENT=#{content}",
             "OPENCODE_AUTH_PATH=#{options["auth_path"]}",
             "OPENCODE_CONFIG_PATH=#{options["config_path"]}",
             "HOME=/tmp/agent-home"
           ],
           llm_egress: :engine
       }}
    end
  end

  defp opencode_gateway_config(model, gateway_token, tools_token, context, spec) do
    base_url =
      case context.host_base_url do
        base when is_binary(base) -> String.trim_trailing(base, "/") <> "/api/v1/gateway/v1"
        _ -> Omashiki.Gateway.openai_base_url()
      end

    config = %{
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

    env = context.environment || %{}
    servers = Map.get(env, "mcp_servers", %{})

    if is_map(servers) and map_size(servers) > 0 do
      Map.merge(
        config,
        Omashiki.Tools.McpConfig.render(env, spec, %{
          token: tools_token,
          base_url: context.host_base_url
        })
      )
    else
      config
    end
    |> Jason.encode!()
  end

  defp build_argv(manifest, options) do
    template = Map.get(manifest.argv, "template", [])
    base = substitute_list(template, bindings(options, %{}))

    Enum.reduce(manifest.option_argv, base, fn rule, acc ->
      opt = Map.get(rule, "option")
      val = Map.get(options, opt)

      cond do
        Map.get(rule, "when_present") == true and val not in [nil, ""] ->
          acc ++ substitute_list(Map.get(rule, "append", []), bindings(options, %{}))

        not is_nil(Map.get(rule, "when_value")) and val == Map.get(rule, "when_value") ->
          acc ++ substitute_list(Map.get(rule, "append", []), bindings(options, %{}))

        is_list(val) and val != [] ->
          Enum.reduce(val, acc, fn item, a ->
            a ++
              substitute_list(Map.get(rule, "append", []), bindings(options, %{"item" => item}))
          end)

        true ->
          acc
      end
    end)
  end

  defp static_env(manifest, options) do
    manifest.env
    |> Map.reject(fn {k, _} -> k == "gateway" end)
    |> Enum.map(fn {k, v} -> "#{k}=#{substitute(v, bindings(options, %{}))}" end)
  end

  defp secret_plan(%Manifest{transport: "http", http: http}, options) when is_map(http) do
    case Map.get(http, "secret_target") do
      target when is_binary(target) -> %{"target" => substitute(target, bindings(options, %{}))}
      _ -> %{"target" => Map.get(options, "auth_path")}
    end
  end

  defp secret_plan(_, _), do: nil

  defp merged_options(%Manifest{options: schema}, raw) do
    defaults =
      schema
      |> Enum.map(fn {k, spec} -> {k, Map.get(spec, "default")} end)
      |> Map.new()

    Map.merge(defaults, raw)
  end

  defp bindings(options, extra) do
    options
    |> stringify_option_keys()
    |> Map.merge(%{"instruction" => nil})
    |> Map.merge(extra)
  end

  defp stringify_option_keys(options) when is_map(options) do
    Map.new(options, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp substitute(template, bindings) when is_binary(template) do
    Regex.replace(~r/\{\{([a-z_]+)\}\}/, template, fn _, key ->
      case Map.get(bindings, key) do
        nil -> ""
        v when is_integer(v) -> Integer.to_string(v)
        v -> to_string(v)
      end
    end)
  end

  defp substitute_list(list, bindings) when is_list(list),
    do: Enum.map(list, &substitute(&1, bindings))

  defp file_secret(
         %Manifest{files: %{"invocation" => %{"path" => path_tpl, "body" => body_tpl}}},
         options,
         prompt
       ) do
    bindings = bindings(options, %{"instruction" => prompt})

    %{
      "target" => substitute(path_tpl, bindings),
      "contents" => substitute(body_tpl, bindings)
    }
  end

  defp file_secret(%Manifest{files: files}, options, prompt) when map_size(files) > 0 do
    {_name, spec} = files |> Map.to_list() |> hd()
    bindings = bindings(options, %{"instruction" => prompt})

    %{
      "target" => substitute(spec["path"], bindings),
      "contents" => substitute(spec["body"], bindings)
    }
  end

  defp file_secret(_, options, prompt) do
    %{"target" => options["invocation_path"], "contents" => prompt}
  end

  defp launch_plan!(spec) do
    {:ok, plan} = launch_plan(spec)
    plan
  end

  defp manifest!(%Preset{manifest: %Manifest{} = m}), do: m
  defp manifest!(%{"manifest" => m}), do: Manifest.from_snapshot(m)

  defp message_payload(%Invocation{instruction: i, context: nil}),
    do: %{parts: [%{type: "text", text: i}]}

  defp message_payload(%Invocation{instruction: i, context: c}),
    do: %{parts: [%{type: "text", text: i <> "\n\nContext:\n" <> Jason.encode!(c)}]}

  defp put_model(payload, credential, :gateway, _manifest, ctx) do
    case gateway_model(credential, ctx) do
      model when is_binary(model) and model != "" ->
        Map.put(payload, :model, %{providerID: "gateway", modelID: model})

      _ ->
        payload
    end
  end

  defp put_model(payload, credential, _, _manifest, ctx) do
    preset_model = profile_option(ctx.profile, "model")
    fallback = if match?(%Credential{}, credential), do: credential.model

    provider_fallback =
      if match?(%Credential{}, credential), do: credential.provider, else: "opencode"

    case preset_model || fallback do
      model when is_binary(model) and model != "" ->
        {provider, model_id} = split_provider_model(model, provider_fallback)
        Map.put(payload, :model, %{providerID: provider, modelID: model_id})

      _ ->
        payload
    end
  end

  defp gateway_model(%Credential{model: model}, _ctx)
       when is_binary(model) and model != "",
       do: model

  defp gateway_model(_credential, ctx), do: profile_option(ctx.profile, "model")

  defp profile_option(profile, key) when is_binary(key) do
    case options_map(profile) do
      options when is_map(options) ->
        Map.get(options, key) || Map.get(options, existing_atom(key))

      _ ->
        nil
    end
  end

  defp options_map(%{options: options}), do: options
  defp options_map(%{"options" => options}), do: options
  defp options_map(_), do: nil

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp split_provider_model(model, fallback) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      [provider, id] when provider != "" and id != "" -> {provider, id}
      _ -> {fallback, model}
    end
  end

  defp normalize_http_result({:ok, %Result{} = r}), do: {:ok, r}
  defp normalize_http_result({:ok, map}) when is_map(map), do: {:ok, Result.from_map(map)}
  defp normalize_http_result(other), do: other

  defp credential_from_environment(environment) when is_map(environment) do
    environment
    |> Map.get(:credentials, Map.get(environment, "credentials", []))
    |> List.wrap()
    |> List.first()
    |> Omashiki.Credentials.pin()
  end

  defp credential_from_environment(_), do: nil
end
