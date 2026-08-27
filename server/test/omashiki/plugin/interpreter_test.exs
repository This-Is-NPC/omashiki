defmodule Omashiki.Plugin.InterpreterTest do
  use ExUnit.Case, async: true

  alias Omashiki.Harness.{Context, Invocation}
  alias Omashiki.Plugin.{Interpreter, Loader, Manifest, Preset}
  alias Omashiki.Isolation
  alias Omashiki.Runtime.Capability

  @plugins_dir Path.expand("../../../../plugins", __DIR__)

  setup do
    plugins = Loader.load!(@plugins_dir)
    manifest = Map.fetch!(plugins, "jcode")
    {:ok, manifest: manifest, plugins: plugins}
  end

  test "loads all five shipped plugin manifests", %{plugins: plugins} do
    for name <- ~w(jcode pi codex claude-code opencode) do
      assert %Manifest{name: ^name} = Map.fetch!(plugins, name)
    end
  end

  test "rejects unknown template variables at parse time" do
    path = Path.join(System.tmp_dir!(), "bad-plugin-#{System.unique_integer([:positive])}.toml")
    File.write!(path, "transport = \"cli\"\n[[option_argv]]\nappend = [\"{{not_allowed}}\"]\n[output]\nshape = \"object\"\ntext = \"text\"\n")

    try do
      assert_raise Omashiki.Config.Error, ~r/unknown template variable/, fn ->
        Manifest.parse!("bad", path, File.read!(path))
      end
    after
      File.rm(path)
    end
  end

  test "decodes jcode object output through the interpreter", %{manifest: manifest} do
    preset = preset(manifest, %{})
    context = cli_context(preset, %{exit_code: 0, stdout: jcode_object_stdout()})

    assert {:ok, result} = Interpreter.invoke(%Invocation{instruction: "say hi", context: nil}, context)
    assert result.assistant_text == "HELLO"
    assert result.input_tokens == 12_331
    assert result.output_tokens == 16
    assert result.cached_input_tokens == 0
    assert result.cache_write_tokens == nil
  end

  test "folds pi jsonl_agent_end output and sums usage across turns", %{plugins: plugins} do
    manifest = Map.fetch!(plugins, "pi")
    preset = preset(manifest, %{})
    context = cli_context(preset, %{exit_code: 0, stdout: pi_agent_end_stream()})

    assert {:ok, result} = Interpreter.invoke(%Invocation{instruction: "say hi", context: nil}, context)
    assert result.assistant_text == "HELLO"
    assert result.input_tokens == 900
    assert result.output_tokens == 60
    assert result.cached_input_tokens == 1_973
    assert result.cache_write_tokens == 0
    assert result.model_resolved == "qwen2.5-coder-3b-instruct"
    assert result.provider == "local"
  end

  test "rejects pi streams that never report agent_end", %{plugins: plugins} do
    manifest = Map.fetch!(plugins, "pi")
    preset = preset(manifest, %{})

    stream =
      [%{"type" => "session", "id" => "01a03ff3"}, %{"type" => "turn_start"}]
      |> Enum.map_join("\n", &Jason.encode!/1)

    context = cli_context(preset, %{exit_code: 0, stdout: stream})

    assert {:error, {:unexpected_json, _}} =
             Interpreter.invoke(%Invocation{instruction: "say hi", context: nil}, context)
  end

  test "decodes claude-code result_envelope output through the interpreter", %{plugins: plugins} do
    manifest = Map.fetch!(plugins, "claude-code")
    preset = preset(manifest, %{})

    stdout =
      Jason.encode!(%{
        "type" => "result",
        "is_error" => false,
        "result" => "created",
        "model" => "claude-sonnet-4-5",
        "usage" => %{
          "input_tokens" => 11,
          "output_tokens" => 7,
          "cache_read_input_tokens" => 3,
          "cache_creation_input_tokens" => 1
        }
      })

    context = cli_context(preset, %{exit_code: 0, stdout: stdout})

    assert {:ok, result} = Interpreter.invoke(%Invocation{instruction: "run", context: nil}, context)
    assert result.assistant_text == "created"
    assert result.input_tokens == 11
    assert result.output_tokens == 7
    assert result.cached_input_tokens == 3
    assert result.cache_write_tokens == 1
    assert result.model_resolved == "claude-sonnet-4-5"
    assert result.provider == "anthropic"
  end

  test "decodes codex result_envelope output through the interpreter", %{plugins: plugins} do
    manifest = Map.fetch!(plugins, "codex")
    preset = preset(manifest, %{"model" => "gpt-5.6-codex"})

    stdout =
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
      })

    context = cli_context(preset, %{exit_code: 0, stdout: stdout})

    assert {:ok, result} = Interpreter.invoke(%Invocation{instruction: "run", context: nil}, context)
    assert result.assistant_text == "created"
    assert result.input_tokens == 14_486
    assert result.output_tokens == 6
    assert result.cached_input_tokens == 9_984
    assert result.cache_write_tokens == 0
    assert result.model_resolved == "gpt-5.6-codex"
    assert result.provider == "openai"
  end

  test "validate_options callback enforces manifest option schema", %{manifest: manifest} do
    assert :ok = Interpreter.validate_options(manifest, %{})
    assert {:error, {:unknown_options, ["bogus"]}} = Interpreter.validate_options(manifest, %{"bogus" => true})
  end

  test "expands list option_argv with {{item}} for claude-code", %{plugins: plugins} do
    manifest = Map.fetch!(plugins, "claude-code")
    preset = preset(manifest, %{})
    argv = preset.launch_plan.transport["argv"]
    tools = ["Read", "Edit", "Write", "Glob", "Grep", "Bash(git *)", "Bash(python3 *)"]

    refute "PLACEHOLDER" in argv

    assert Enum.flat_map(tools, &["--allowed-tool", &1]) ==
             argv
             |> Enum.chunk_every(2)
             |> Enum.filter(&match?(["--allowed-tool", _], &1))
             |> List.flatten()
  end

  test "admitted snapshot keeps only path, contents, and digest", %{manifest: manifest} do
    snapshot = Manifest.admitted_snapshot(manifest)

    assert Map.keys(snapshot) |> Enum.sort() == ["contents", "digest", "path"]
    assert snapshot["path"] == manifest.path
    assert snapshot["contents"] == manifest.contents
    assert snapshot["digest"] == manifest.digest
  end

  defp preset(manifest, options) do
    runtime = %Isolation{
      key: manifest.name,
      kind: "docker",
      config: %{"image" => "agent"},
      status: "active"
    }

    base = %Preset{
      name: manifest.name,
      adapter: Interpreter,
      adapter_key: manifest.name,
      options: options,
      runtime: runtime,
      launch_plan: nil,
      manifest: manifest
    }

    {:ok, plan} = Interpreter.launch_plan(base)
    %{base | launch_plan: plan}
  end

  defp cli_context(preset, output) do
    %Context{
      job: nil,
      profile: preset,
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

  defp jcode_object_stdout do
    Jason.encode!(%{
      "session_id" => "session_x",
      "provider" => "llamacpp",
      "model" => "qwen2.5-coder-1.5b-instruct",
      "text" => "HELLO",
      "usage" => %{
        "input_tokens" => 12_331,
        "output_tokens" => 16,
        "cache_read_input_tokens" => 0,
        "cache_creation_input_tokens" => nil
      }
    })
  end

  defp pi_agent_end_stream do
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
            "usage" => %{"input" => 820, "output" => 3, "cacheRead" => 577, "cacheWrite" => 0}
          },
          %{
            "role" => "assistant",
            "provider" => "local",
            "model" => "qwen2.5-coder-3b-instruct",
            "content" => [%{"type" => "text", "text" => "HELLO"}],
            "usage" => %{"input" => 80, "output" => 57, "cacheRead" => 1_396, "cacheWrite" => 0}
          }
        ]
      },
      %{"type" => "agent_settled"}
    ]
    |> Enum.map_join("\n", &Jason.encode!/1)
  end
end
