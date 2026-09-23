defmodule Omashiki.Config.CheckTest do
  @moduledoc """
  `check/3` is `load!/1` without the publish.

  The editor asks "would this file load?" before anything is written, so the
  answer has to be the loader's own: the same build, the same messages, and
  the live generation untouched whatever the verdict.
  """

  use ExUnit.Case, async: false

  alias Omashiki.Config
  import Omashiki.Fixtures

  setup do
    Config.reset!()
    root = Path.join(System.tmp_dir!(), "omashiki-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    copy_plugins!(root)
    assert {_output, 0} = System.cmd("git", ["init", "--quiet", Path.join(root, "repo")])

    on_exit(fn ->
      Config.reset!()
      File.rm_rf!(root)
    end)

    %{root: root, path: Path.join(root, "omashiki.toml")}
  end

  test "rejects a bad file with exactly the message load! raises", ctx do
    File.write!(Path.join(ctx.root, "bad.toml"), "not [ toml")

    for content <- [
          "not [ toml",
          String.replace(house_toml(), "[limits]", "[limitz]"),
          "[harnesses.x]\n" <> house_toml(),
          ~s(include = ["nope.toml"]\n) <> house_toml(),
          ~s(include = ["bad.toml"]\n) <> house_toml(),
          house_toml(model: "")
        ] do
      File.write!(ctx.path, content)
      error = assert_raise Config.Error, fn -> Config.load!(ctx.path) end
      assert Config.check(content, ctx.path) == {:error, Exception.message(error)}
    end
  end

  test "never publishes, valid or not", ctx do
    File.write!(ctx.path, house_toml())
    assert :ok = Config.load!(ctx.path)
    generation = Config.generation()

    assert {:ok, _summary} = Config.check(house_toml(model: "other"), ctx.path)
    assert {:error, _message} = Config.check("not [ toml", ctx.path)

    assert Config.generation() == generation
    assert [%{model: "some-model"}] = Config.credentials()
  end

  test "reads a piece from the given content instead of its file", ctx do
    piece = Path.join(ctx.root, "credentials.toml")
    File.write!(piece, credential_toml("some-model"))
    root = ~s(include = ["credentials.toml"]\n) <> house_toml(credentials: false)

    assert {:ok, _summary} = Config.check(root, ctx.path)

    assert {:error, message} =
             Config.check(root, ctx.path, pieces: %{piece => "[limits]\npids_limit = 1\n"})

    assert message =~ "[limits] must stay in omashiki.toml"
  end

  test "summarizes what changes against the live generation", ctx do
    File.write!(ctx.path, house_toml())
    assert :ok = Config.load!(ctx.path)

    candidate =
      house_toml(model: "new-model", containers: 8) <>
        """

        [app]
        port = 4100

        [credentials.spare]
        provider = "openai_compat"
        model = "spare-model"
        api_key = "plaintext-key"
        """

    assert {:ok, summary} = Config.check(candidate, ctx.path)
    assert summary.credentials == %{added: ["spare"], removed: [], changed: ["provider"]}
    # The environment carries the credential it resolves, so it changes too.
    assert summary.environments == %{added: [], removed: [], changed: ["opencode"]}
    assert summary.presets == %{added: [], removed: [], changed: []}
    assert summary.restart_required == ["app", "limits"]

    assert {:ok, %{restart_required: []}} =
             Config.check(house_toml(model: "new-model"), ctx.path)
  end
end
