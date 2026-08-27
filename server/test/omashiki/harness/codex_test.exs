defmodule Omashiki.Harness.CodexTest do
  use ExUnit.Case, async: true

  alias Omashiki.Plugin.Preset
  alias Omashiki.Isolation

  alias Omashiki.Harness.{Context, Invocation}
  alias Omashiki.Plugin.Preset
  alias Omashiki.Harness.Codex
  alias Omashiki.Runtime.Capability
  alias Omashiki.Isolation

  test "validates the strict profile surface" do
    assert :ok = Codex.validate_options(%{})

    assert {:error, {:unknown_options, ["allowed_tools"]}} =
             Codex.validate_options(%{"allowed_tools" => ["Read"]})

    assert {:error, :invalid_timeout} = Codex.validate_options(%{"timeout_ms" => 0})
    assert {:error, :invalid_web_search} = Codex.validate_options(%{"web_search" => "yes"})
    assert {:error, :invalid_model} = Codex.validate_options(%{"model" => "--oss"})

    assert {:error, :invalid_reasoning_effort} =
             Codex.validate_options(%{"reasoning_effort" => "lowest"})

    assert :ok = Codex.validate_options(%{"reasoning_effort" => "low"})

    assert {:error, :invalid_invocation_path} =
             Codex.validate_options(%{"invocation_path" => "/etc/invocation.json"})

    assert {:error, :invalid_credentials_path} =
             Codex.validate_options(%{"credentials_path" => "/etc/codex-auth.json"})
  end

  test "selects Codex from an immutable string-keyed environment snapshot" do
    spec = profile(%{})

    snapshot = %{
      "preset" => %{
        "name" => spec.name,
        "adapter_key" => spec.adapter_key,
        "options" => spec.options,
        "runtime" => %{"kind" => "docker", "config" => %{"image" => "agent"}},
        "launch_plan" => %{
          "transport" => %{"kind" => "cli"},
          "startup" => nil,
          "readiness" => nil,
          "secret" => nil,
          "environment" => []
        }
      }
    }

    assert Omashiki.Harnesses.adapter(snapshot) == Codex
  end

  test "builds a CLI plan with a login readiness probe and web search off" do
    spec = profile(%{"model" => "gpt-5.6-codex"})
    assert {:ok, plan} = Codex.launch_plan(spec)
    assert plan.transport["kind"] == "cli"
    assert plan.llm_egress == :engine

    assert plan.readiness == %{
             "kind" => "exec",
             "argv" => ["/usr/local/bin/codex", "login", "status"],
             "timeout_ms" => 10_000
           }

    assert plan.transport["argv"] == [
             Codex.runner_path(),
             Codex.invocation_path(),
             "--model",
             "gpt-5.6-codex"
           ]

    assert "CODEX_HOME=#{Codex.codex_home()}" in plan.environment
    assert "CODEX_CREDENTIALS_PATH=#{Codex.credentials_path()}" in plan.environment

    assert {:ok, searching} = Codex.launch_plan(profile(%{"web_search" => true}))

    assert searching.transport["argv"] == [
             Codex.runner_path(),
             Codex.invocation_path(),
             "--web-search"
           ]

    # Effort is a separate flag, never a `model:effort` slug.
    assert {:ok, low} =
             Codex.launch_plan(profile(%{"model" => "gpt-5.6-luna", "reasoning_effort" => "low"}))

    assert low.transport["argv"] == [
             Codex.runner_path(),
             Codex.invocation_path(),
             "--model",
             "gpt-5.6-luna",
             "--reasoning-effort",
             "low"
           ]
  end

  test "prepares the neutral payload as a runtime secret" do
    spec = profile(%{})
    payload = %{"instruction" => "make secret", "context" => %{"x" => 1}}

    context = %Context{
      job: %{payload: payload},
      runtime_mounts: [{__ENV__.file, Codex.credentials_path(), false}]
    }

    assert {:ok, plan} = Codex.prepare(spec, context)
    assert plan.secret["target"] == Codex.invocation_path()
    assert Jason.decode!(plan.secret["contents"]) == payload
  end

  test "rejects a read-only or missing credentials mount" do
    spec = profile(%{})
    payload = %{"instruction" => "make secret", "context" => nil}

    read_only = %Context{
      job: %{payload: payload},
      runtime_mounts: [{__ENV__.file, Codex.credentials_path(), true}]
    }

    assert {:error, {:codex_credentials_mount_must_be_writable, _}} =
             Codex.prepare(spec, read_only)

    assert {:error, {:codex_credentials_mount_missing, _}} =
             Codex.prepare(spec, %{read_only | runtime_mounts: []})
  end

  test "never places the invocation in CLI argv and maps Codex usage" do
    parent = self()

    capability = %Capability{
      transport: :cli,
      endpoint: nil,
      exec: fn argv, _timeout ->
        send(parent, {:exec, argv})

        {:ok,
         %{
           stdout:
             Jason.encode!(%{
               "type" => "result",
               "is_error" => false,
               "result" => "created",
               "model" => "gpt-5.6-codex",
               "thread_id" => "01a0",
               "usage" => %{
                 "input_tokens" => 14_486,
                 "cached_input_tokens" => 9_984,
                 "cache_write_input_tokens" => 0,
                 "output_tokens" => 6,
                 "reasoning_output_tokens" => 0
               }
             }),
           exit_code: 0
         }}
      end
    }

    spec = profile(%{"model" => "gpt-5.6-codex"})
    context = %Context{profile: spec, capability: capability}

    assert {:ok, result} =
             Codex.invoke(%Invocation{instruction: "make secret", context: %{"x" => 1}}, context)

    assert result.assistant_text == "created"
    assert result.input_tokens == 14_486
    assert result.output_tokens == 6
    assert result.cached_input_tokens == 9_984
    assert result.cache_write_tokens == 0
    assert result.model_resolved == "gpt-5.6-codex"
    assert result.provider == "openai"

    assert_receive {:exec, argv}
    refute Enum.any?(argv, &String.contains?(&1, "make secret"))
    refute Enum.any?(argv, &String.contains?(&1, "\"x\""))
  end

  test "reports absent usage as nil rather than zero" do
    capability = %Capability{
      transport: :cli,
      endpoint: nil,
      exec: fn _argv, _timeout ->
        {:ok,
         %{
           stdout: Jason.encode!(%{"type" => "result", "is_error" => false, "result" => "done"}),
           exit_code: 0
         }}
      end
    }

    context = %Context{profile: profile(%{}), capability: capability}

    assert {:ok, result} = Codex.invoke(%Invocation{instruction: "run", context: nil}, context)

    assert result.assistant_text == "done"
    assert result.input_tokens == nil
    assert result.output_tokens == nil
    assert result.cached_input_tokens == nil
    assert result.cache_write_tokens == nil
    assert result.model_resolved == nil
  end

  test "reports explicit exit, turn failure and non-JSON failures" do
    capability = fn output ->
      %Capability{transport: :cli, endpoint: nil, exec: fn _argv, _timeout -> output end}
    end

    spec = profile(%{})

    exit_context = %Context{
      profile: spec,
      capability: capability.({:ok, %{stdout: "failed", exit_code: 9}})
    }

    json_context = %Context{
      profile: spec,
      capability: capability.({:ok, %{stdout: "not json", exit_code: 0}})
    }

    turn_context = %Context{
      profile: spec,
      capability:
        capability.(
          {:ok,
           %{
             stdout:
               Jason.encode!(%{
                 "type" => "result",
                 "is_error" => true,
                 "result" => "model is not supported"
               }),
             exit_code: 0
           }}
        )
    }

    assert {:error, {:codex_exit, 9, "failed"}} =
             Codex.invoke(%Invocation{instruction: "run", context: nil}, exit_context)

    assert {:error, {:codex_non_json_output, "not json"}} =
             Codex.invoke(%Invocation{instruction: "run", context: nil}, json_context)

    assert {:error, {:codex_result_error, "model is not supported"}} =
             Codex.invoke(%Invocation{instruction: "run", context: nil}, turn_context)
  end

  test "parses the final JSON object after diagnostic output" do
    capability = %Capability{
      transport: :cli,
      endpoint: nil,
      exec: fn _argv, _timeout ->
        {:ok,
         %{
           stdout:
             "[stderr] transient warning\n" <>
               Jason.encode!(%{"type" => "result", "is_error" => false, "result" => "created"}),
           exit_code: 0
         }}
      end
    }

    context = %Context{profile: profile(%{}), capability: capability}

    assert {:ok, result} = Codex.invoke(%Invocation{instruction: "run", context: nil}, context)
    assert result.assistant_text == "created"
  end

  test "rejects an empty invocation before touching the runtime" do
    capability = %Capability{
      transport: :cli,
      endpoint: nil,
      exec: fn _argv, _timeout -> flunk("runtime must not be reached") end
    }

    context = %Context{profile: profile(%{}), capability: capability}

    assert {:error, :invalid_invocation} =
             Codex.invoke(%Invocation{instruction: "", context: nil}, context)
  end

  defp profile(options) do
    %Preset{
      name: "codex",
      adapter: Codex,
      adapter_key: "codex",
      options: options,
      runtime: %Isolation{
        key: "codex",
        kind: "docker",
        config: %{"image" => "agent"},
        status: "active"
      },
      launch_plan: nil
    }
  end
end
