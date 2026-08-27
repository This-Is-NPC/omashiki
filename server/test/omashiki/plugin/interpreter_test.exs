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

  test "decodes jcode jsonl_agent_end output through the interpreter", %{manifest: manifest} do
    preset = preset(manifest, %{})

    output = %{
      exit_code: 0,
      stdout:
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
    }

    context = %Context{
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

    assert {:ok, result} = Interpreter.invoke(%Invocation{instruction: "say hi", context: nil}, context)
    assert result.assistant_text == "HELLO"
    assert result.input_tokens == 12_331
    assert result.output_tokens == 16
    assert result.cached_input_tokens == 0
    assert result.cache_write_tokens == nil
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
end
