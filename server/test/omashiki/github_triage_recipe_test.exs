defmodule Omashiki.GithubTriageRecipeTest do
  @moduledoc """
  The GitHub triage recipe in examples/github-triage keeps working.

  The piece is included exactly as its README says, the reference handler
  turns a new issue into an envelope with the recipe's instruction, and the
  house admits that envelope as a none job wearing the triage identity. No
  network: the handler runs as a function, not a server.
  """

  use Omashiki.DataCase, async: false

  alias Omashiki.Config
  alias Omashiki.Config.{Environment, Identity}
  alias Omashiki.Jobs.Admission

  @examples Path.expand("../../../examples", __DIR__)
  @recipe Path.join(@examples, "github-triage")
  @handler Path.join(@examples, "handler/github_issue_handler.py")
  @key_var "TRIAGE_BOT_PRIVATE_KEY"

  setup do
    root = Path.join(System.tmp_dir!(), "omashiki-triage-#{System.unique_integer([:positive])}")
    piece_dir = Path.join(root, "examples/github-triage")
    File.mkdir_p!(piece_dir)
    File.cp!(Path.join(@recipe, "triage.toml"), Path.join(piece_dir, "triage.toml"))
    copy_plugins!(root)

    System.put_env(
      @key_var,
      "-----BEGIN RSA PRIVATE KEY-----\ntest\n-----END RSA PRIVATE KEY-----"
    )

    on_exit(fn ->
      Config.reset!()
      System.delete_env(@key_var)
      File.rm_rf!(root)
    end)

    path = Path.join(root, "omashiki.toml")
    File.write!(path, root_config())
    %{path: path}
  end

  test "the included piece loads the triage environment, identity, and tools", ctx do
    assert :ok = Config.load!(ctx.path)

    assert Config.repositories() == []

    assert %Environment{
             sink: "none",
             network: "restricted",
             executables: [],
             capabilities: ["github_*"],
             pre_steps: [],
             post_steps: []
           } = Config.get_environment("triage")

    assert %Identity{name: "triage-bot", kind: "github-app"} = Config.get_identity("triage-bot")
  end

  test "a new issue becomes an envelope the house admits as a none job", ctx do
    assert :ok = Config.load!(ctx.path)

    envelope = handler_envelope(issue_opened())

    refute Map.has_key?(envelope, "repo")
    assert envelope["environment"] == "triage"

    instruction = envelope["payload"]["instruction"]

    assert String.starts_with?(
             instruction,
             File.read!(Path.join(@recipe, "triage.md")) |> String.trim()
           )

    assert instruction =~ "Issue acme/app#7: Login page throws 500"

    # The token the README issues: this environment, read and submit.
    {token, _plaintext} =
      api_token_fixture(user_fixture(), %{
        scopes: ["read", "submit"],
        allowed_environments: ["triage"]
      })

    assert {:ok, _, job} = Admission.admit_once(token, envelope)

    assert job.repository == nil
    assert job.admitted_environment["sink"] == "none"

    assert [%{"name" => "triage-bot", "kind" => "github-app"}] =
             job.admitted_environment["preset"]["identities"]
  end

  # The reference handler's own mapping, configured the way run.sh does.
  defp handler_envelope(event) do
    script = """
    import importlib.util, json, sys
    spec = importlib.util.spec_from_file_location("handler", sys.argv[1])
    handler = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(handler)
    cfg = handler.config_from_env()
    print(json.dumps(handler.envelope_for("issues", json.loads(sys.argv[2]), cfg)))
    """

    env = [
      {"OMASHIKI_URL", "http://127.0.0.1:4010"},
      {"OMASHIKI_TOKEN", "unused"},
      {"OMASHIKI_ENVIRONMENT", "triage"},
      {"OMASHIKI_REPO", nil},
      {"GITHUB_WEBHOOK_SECRET", "unused"},
      {"HANDLER_TRIGGER", "opened"},
      {"HANDLER_INSTRUCTION", Path.join(@recipe, "triage.md")}
    ]

    assert {output, 0} =
             System.cmd("python3", ["-c", script, @handler, Jason.encode!(event)],
               env: env,
               stderr_to_stdout: true
             )

    Jason.decode!(output)
  end

  defp issue_opened do
    %{
      "action" => "opened",
      "issue" => %{
        "number" => 7,
        "title" => "Login page throws 500",
        "body" => "Steps: open /login",
        "html_url" => "https://github.test/acme/app/issues/7",
        "labels" => [],
        "user" => %{"login" => "ana"}
      },
      "repository" => %{"id" => 99, "full_name" => "acme/app"}
    }
  end

  # A house with only the recipe: no [repositories], the image catalog, and
  # the host credential the piece names.
  defp root_config do
    """
    include = ["examples/github-triage/triage.toml"]

    [limits]
    max_concurrent_containers = 4

    [runtimes.docker.runc.debian.images]
    opencode = "omashiki/agent:latest"

    [host_credentials.opencode-local]
    kind = "opencode"
    auth = "~/.local/share/opencode/auth.json"
    config = "~/.config/opencode/opencode.json"
    """
  end
end
