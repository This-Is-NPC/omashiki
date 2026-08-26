defmodule Omashiki.Harness.PiTest do
  use ExUnit.Case, async: true

  alias Omashiki.Harness.{Context, Invocation, Spec}
  alias Omashiki.Harness.Pi
  alias Omashiki.Runtime.Capability
  alias Omashiki.Runtimes.Runtime

  test "validates the strict profile surface" do
    assert :ok = Pi.validate_options(%{})

    assert {:error, {:unknown_options, ["thinking"]}} =
             Pi.validate_options(%{"thinking" => "high"})

    assert {:error, :invalid_timeout} = Pi.validate_options(%{"timeout_ms" => 0})
    assert {:error, :invalid_model} = Pi.validate_options(%{"model" => "--offline"})

    assert {:error, :invalid_invocation_path} =
             Pi.validate_options(%{"invocation_path" => "/etc/prompt.txt"})
  end

  test "builds a CLI plan that carries only the prompt path in argv" do
    assert {:ok, plan} = Pi.launch_plan(profile(%{}))
    assert plan.transport["kind"] == "cli"
    # pi has no host-auth route: it always reaches the model via the gateway.
    assert plan.llm_egress == :gateway
    assert plan.transport["argv"] == [Pi.runner_path(), Pi.invocation_path()]
    assert "PI_CODING_AGENT_DIR=#{Pi.agent_dir()}" in plan.environment

    assert {:ok, pinned} = Pi.launch_plan(profile(%{"model" => "qwen2.5-coder-3b-instruct"}))

    assert pinned.transport["argv"] == [
             Pi.runner_path(),
             Pi.invocation_path(),
             "--model",
             "qwen2.5-coder-3b-instruct"
           ]
  end

  # Not a style preference. Without PI_OFFLINE pi performs a startup catalog
  # fetch and blocks indefinitely when that route is unavailable, so on a
  # restricted-network container its absence is a silent boot hang. It is
  # asserted here because nothing else in the system would notice it going
  # missing until every attempt timed out.
  test "always launches pi with startup network operations disabled" do
    assert {:ok, plan} = Pi.launch_plan(profile(%{}))
    assert "PI_OFFLINE=1" in plan.environment
  end

  test "folds the pi event stream and sums usage across turns" do
    # pi --mode json emits newline-delimited events, not one object. Only
    # `agent_end` carries the whole conversation, and usage is reported per
    # assistant message, so a two-turn run has to add up to 900/60.
    stream =
      [
        %{"type" => "session", "id" => "01a03ff3"},
        %{"type" => "turn_start"},
        %{
          "type" => "agent_end",
          "messages" => [
            %{"role" => "user", "content" => [%{"type" => "text", "text" => "do the thing"}]},
            %{
              "role" => "assistant",
              "provider" => "local",
              "model" => "qwen2.5-coder-3b-instruct",
              "content" => [%{"type" => "text", "text" => "first"}],
              "usage" => %{
                "input" => 820,
                "output" => 3,
                "cacheRead" => 577,
                "cacheWrite" => 0
              }
            },
            %{
              "role" => "assistant",
              "provider" => "local",
              "model" => "qwen2.5-coder-3b-instruct",
              "content" => [%{"type" => "text", "text" => "HELLO"}],
              "usage" => %{
                "input" => 80,
                "output" => 57,
                "cacheRead" => 1_396,
                "cacheWrite" => 0
              }
            }
          ]
        },
        %{"type" => "agent_settled"}
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)

    assert {:ok, result} =
             Pi.invoke(invocation(), context_returning(%{exit_code: 0, stdout: stream}))

    assert result.assistant_text == "HELLO"
    assert result.input_tokens == 900
    assert result.output_tokens == 60
    assert result.cached_input_tokens == 1_973
    assert result.cache_write_tokens == 0
    assert result.model_resolved == "qwen2.5-coder-3b-instruct"
    assert result.provider == "local"
  end

  test "rejects a stream that never reported a completed run" do
    stream =
      [%{"type" => "session", "id" => "01a03ff3"}, %{"type" => "turn_start"}]
      |> Enum.map_join("\n", &Jason.encode!/1)

    assert {:error, {:pi_unexpected_json, _}} =
             Pi.invoke(invocation(), context_returning(%{exit_code: 0, stdout: stream}))
  end

  test "never places the prompt in the exec argv" do
    parent = self()

    context = %Context{
      job: nil,
      profile: profile(%{}),
      capability: %Capability{
        transport: :cli,
        endpoint: nil,
        exec: fn argv, _timeout ->
          send(parent, {:exec, argv})

          {:ok,
           %{
             exit_code: 0,
             stdout:
               Jason.encode!(%{
                 "type" => "agent_end",
                 "messages" => [
                   %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "ok"}]}
                 ]
               })
           }}
        end
      },
      environment: %{},
      runtime_mounts: [],
      credential: nil
    }

    assert {:ok, _result} = Pi.invoke(invocation("make secret"), context)
    assert_receive {:exec, argv}
    refute Enum.any?(argv, &String.contains?(&1, "make secret"))
  end

  defp context_returning(output) do
    %Context{
      job: nil,
      profile: profile(%{}),
      capability: %Capability{
        transport: :cli,
        endpoint: nil,
        exec: fn _argv, _timeout -> {:ok, output} end
      },
      environment: %{},
      runtime_mounts: [],
      credential: nil
    }
  end

  defp invocation(instruction \\ "do the thing"),
    do: %Invocation{instruction: instruction, context: %{}}

  defp profile(options) do
    %Spec{
      name: "pi",
      adapter_key: "pi",
      adapter: Pi,
      options: options,
      runtime: %Runtime{
        key: "pi",
        kind: "docker",
        config: %{"image" => "omashiki/agent-pi:latest"},
        status: "active"
      },
      launch_plan: nil
    }
  end
end
