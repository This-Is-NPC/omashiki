defmodule Omashiki.Harness.JcodeTest do
  use ExUnit.Case, async: true

  alias Omashiki.Harness.{Context, Invocation, Spec}
  alias Omashiki.Harness.Jcode
  alias Omashiki.Runtime.Capability
  alias Omashiki.Runtimes.Runtime

  test "validates the strict profile surface" do
    assert :ok = Jcode.validate_options(%{})

    assert {:error, {:unknown_options, ["web_search"]}} =
             Jcode.validate_options(%{"web_search" => true})

    assert {:error, :invalid_timeout} = Jcode.validate_options(%{"timeout_ms" => 0})
    assert {:error, :invalid_model} = Jcode.validate_options(%{"model" => "--oss"})

    assert {:error, :invalid_invocation_path} =
             Jcode.validate_options(%{"invocation_path" => "/etc/prompt.txt"})
  end

  test "builds a CLI plan that carries only the prompt path in argv" do
    assert {:ok, plan} = Jcode.launch_plan(profile(%{}))
    assert plan.transport["kind"] == "cli"
    # jcode has no host-auth route: it always reaches the model via the gateway.
    assert plan.llm_egress == :gateway
    assert plan.transport["argv"] == [Jcode.runner_path(), Jcode.invocation_path()]
    assert "JCODE_HOME=#{Jcode.jcode_home()}" in plan.environment

    assert {:ok, pinned} = Jcode.launch_plan(profile(%{"model" => "stealth/ox-alpha"}))

    assert pinned.transport["argv"] == [
             Jcode.runner_path(),
             Jcode.invocation_path(),
             "--model",
             "stealth/ox-alpha"
           ]
  end

  test "maps jcode usage and keeps an absent cache counter nil" do
    output = %{
      exit_code: 0,
      stdout:
        Jason.encode!(%{
          "session_id" => "session_x",
          "provider" => "openrouter",
          "model" => "stealth/ox-alpha",
          "text" => "HELLO",
          "usage" => %{
            "input_tokens" => 12_331,
            "output_tokens" => 16,
            "cache_read_input_tokens" => 0,
            "cache_creation_input_tokens" => nil
          }
        })
    }

    context = %Context{
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

    assert {:ok, result} = Jcode.invoke(invocation(), context)
    assert result.assistant_text == "HELLO"
    assert result.input_tokens == 12_331
    assert result.output_tokens == 16
    assert result.cached_input_tokens == 0
    assert result.cache_write_tokens == nil
    assert result.model_resolved == "stealth/ox-alpha"
    assert result.provider == "openrouter"
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
          {:ok, %{exit_code: 0, stdout: Jason.encode!(%{"text" => "ok"})}}
        end
      },
      environment: %{},
      runtime_mounts: [],
      credential: nil
    }

    assert {:ok, _result} = Jcode.invoke(invocation("make secret"), context)
    assert_receive {:exec, argv}
    refute Enum.any?(argv, &String.contains?(&1, "make secret"))
  end

  defp invocation(instruction \\ "do the thing"),
    do: %Invocation{instruction: instruction, context: %{}}

  defp profile(options) do
    %Spec{
      name: "jcode",
      adapter_key: "jcode",
      adapter: Jcode,
      options: options,
      runtime: %Runtime{
        key: "jcode",
        kind: "docker",
        config: %{"image" => "omashiki/agent-jcode:latest"},
        status: "active"
      },
      launch_plan: nil
    }
  end
end
