defmodule Omashiki.Harness.ClaudeCodeTest do
  use ExUnit.Case, async: true

  alias Omashiki.Plugin.Preset
  alias Omashiki.Isolation

  alias Omashiki.Harness.{Context, Invocation}
  alias Omashiki.Plugin.Preset
  alias Omashiki.Harness.ClaudeCode
  alias Omashiki.Runtime.Capability
  alias Omashiki.Isolation

  test "validates the strict profile surface" do
    assert :ok = ClaudeCode.validate_options(%{})

    assert {:error, {:unknown_options, ["extra"]}} =
             ClaudeCode.validate_options(%{"extra" => true})

    assert {:error, :invalid_timeout} = ClaudeCode.validate_options(%{"timeout_ms" => 0})

    assert {:error, :invalid_allowed_tools} =
             ClaudeCode.validate_options(%{"allowed_tools" => ["Bash"]})

    assert {:error, :invalid_invocation_path} =
             ClaudeCode.validate_options(%{"invocation_path" => "/etc/invocation.json"})
  end

  test "selects Claude from an immutable string-keyed environment snapshot" do
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

    assert Omashiki.Harnesses.adapter(snapshot) == ClaudeCode
  end

  test "builds a CLI plan with fixed invocation and tool policy" do
    spec = profile(%{"model" => "claude-sonnet-4-5"})
    assert {:ok, plan} = ClaudeCode.launch_plan(spec)
    assert plan.transport["kind"] == "cli"

    assert plan.readiness == %{
             "kind" => "exec",
             "argv" => ["/usr/local/bin/claude", "auth", "status"],
             "timeout_ms" => 10_000
           }

    assert plan.transport["argv"] == [
             ClaudeCode.runner_path(),
             ClaudeCode.invocation_path(),
             "--allowed-tool",
             "Read",
             "--allowed-tool",
             "Edit",
             "--allowed-tool",
             "Write",
             "--allowed-tool",
             "Glob",
             "--allowed-tool",
             "Grep",
             "--allowed-tool",
             "Bash(git *)",
             "--allowed-tool",
             "Bash(python3 *)",
             "--model",
             "claude-sonnet-4-5"
           ]
  end

  test "prepares the neutral payload as a read-only runtime secret" do
    spec = profile(%{})
    payload = %{"instruction" => "make secret", "context" => %{"x" => 1}}

    context = %Context{
      job: %{payload: payload},
      runtime_mounts: [{__ENV__.file, ClaudeCode.credentials_path(), false}]
    }

    assert {:ok, plan} = ClaudeCode.prepare(spec, context)
    assert plan.secret["target"] == ClaudeCode.invocation_path()
    assert Jason.decode!(plan.secret["contents"]) == payload
  end

  test "never places the invocation in CLI argv" do
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
               "model" => "claude-sonnet-4-5",
               "usage" => %{
                 "input_tokens" => 11,
                 "output_tokens" => 7,
                 "cache_read_input_tokens" => 3
               }
             }),
           exit_code: 0
         }}
      end
    }

    spec = profile(%{"model" => "claude-sonnet-4-5"})
    context = %Context{profile: spec, capability: capability}

    assert {:ok, result} =
             ClaudeCode.invoke(
               %Invocation{instruction: "make secret", context: %{"x" => 1}},
               context
             )

    assert result.assistant_text == "created"
    assert result.input_tokens == 11
    assert result.output_tokens == 7
    assert result.cached_input_tokens == 3
    assert result.model_resolved == "claude-sonnet-4-5"
    assert result.provider == "anthropic"

    assert_receive {:exec, argv}
    refute Enum.any?(argv, &String.contains?(&1, "make secret"))
    refute Enum.any?(argv, &String.contains?(&1, "\"x\""))
  end

  test "reports explicit exit and non-JSON failures" do
    capability = fn output ->
      %Capability{
        transport: :cli,
        endpoint: nil,
        exec: fn _argv, _timeout -> output end
      }
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

    assert {:error, {:claude_exit, 9, "failed"}} =
             ClaudeCode.invoke(%Invocation{instruction: "run", context: nil}, exit_context)

    assert {:error, {:claude_non_json_output, "not json"}} =
             ClaudeCode.invoke(%Invocation{instruction: "run", context: nil}, json_context)
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
               Jason.encode!(%{
                 "type" => "result",
                 "is_error" => false,
                 "result" => "created"
               }),
           exit_code: 0
         }}
      end
    }

    spec = profile(%{})
    context = %Context{profile: spec, capability: capability}

    assert {:ok, result} =
             ClaudeCode.invoke(%Invocation{instruction: "run", context: nil}, context)

    assert result.assistant_text == "created"
  end

  defp profile(options) do
    %Preset{
      name: "claude-code",
      adapter: ClaudeCode,
      adapter_key: "claude-code",
      options: options,
      runtime: %Isolation{
        key: "claude-code",
        kind: "docker",
        config: %{"image" => "agent"},
        status: "active"
      },
      launch_plan: nil
    }
  end
end
