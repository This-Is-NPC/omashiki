defmodule Omashiki.Identities.BrokerTest do
  @moduledoc """
  A job whose preset wears `ana-bot` makes the *house* comment on GitHub.

  The sandbox only ever speaks to the tools data plane with its job-bound
  token. The App JWT, the installation token, and the private key exist in
  this process and nowhere the job can see.
  """

  use Omashiki.DataCase, async: false

  import Omashiki.Fixtures
  import Omashiki.JobFixtures

  alias Omashiki.Config
  alias Omashiki.Identities.GithubApp
  alias Omashiki.Runtime.Claims
  alias Omashiki.Tools.{McpConfig, Proxy}

  @env_var "OMASHIKI_TEST_BROKER_APP_KEY"
  @public %{
    "name" => "ana-bot",
    "kind" => "github-app",
    "app_id" => "123456",
    "installation_id" => "987654"
  }

  setup do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
    public_key = {:RSAPublicKey, elem(key, 2), elem(key, 3)}
    System.put_env(@env_var, pem)

    bypass = Bypass.open()
    Application.put_env(:omashiki, :github_api_base_url, "http://localhost:#{bypass.port}")
    GithubApp.clear_cache()

    root = Path.join(System.tmp_dir!(), "omashiki-broker-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "repo"))
    {_, 0} = System.cmd("git", ["-C", Path.join(root, "repo"), "init", "-q"])
    :ok = Config.load_map!(house(), path: Path.join(root, "omashiki.toml"))

    user = user_fixture()
    {token, _plaintext} = api_token_fixture(user)

    on_exit(fn ->
      Config.reset!()
      GithubApp.clear_cache()
      Application.delete_env(:omashiki, :github_api_base_url)
      System.delete_env(@env_var)
      File.rm_rf!(root)
    end)

    %{bypass: bypass, public_key: public_key, user: user, token: token, root: root}
  end

  test "a preset wearing ana-bot comments on GitHub from the house process", ctx do
    expect_installation_token(ctx, "ghs_live")

    Bypass.expect_once(ctx.bypass, "POST", "/repos/acme/app/issues/7/comments", fn conn ->
      assert ["token ghs_live"] = Plug.Conn.get_req_header(conn, "authorization")
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"body" => "reviewed by the house"} = Jason.decode!(body)
      Plug.Conn.resp(conn, 201, ~s({"id": 1, "html_url": "https://github.test/c/1"}))
    end)

    claims = claims_for(job(ctx, ["github_*"]))

    assert {:ok, %{"result" => %{"isError" => false, "content" => [%{"text" => text}]}}} =
             Proxy.handle_rpc(
               "ana-bot",
               call("github_comment", %{
                 "repository" => "acme/app",
                 "number" => 7,
                 "body" => "reviewed by the house"
               }),
               claims
             )

    assert %{"id" => 1} = Jason.decode!(text)
  end

  test "the installation token is minted once and reused", ctx do
    expect_installation_token(ctx, "ghs_once")

    Bypass.expect(ctx.bypass, "POST", "/repos/acme/app/issues/7/labels", fn conn ->
      assert ["token ghs_once"] = Plug.Conn.get_req_header(conn, "authorization")
      Plug.Conn.resp(conn, 200, "[]")
    end)

    claims = claims_for(job(ctx, ["github_*"]))

    rpc =
      call("github_add_labels", %{"repository" => "acme/app", "number" => 7, "labels" => ["x"]})

    assert {:ok, %{"result" => %{"isError" => false}}} = Proxy.handle_rpc("ana-bot", rpc, claims)
    assert {:ok, %{"result" => %{"isError" => false}}} = Proxy.handle_rpc("ana-bot", rpc, claims)
  end

  test "a GitHub error is reported to the agent as a tool error, not a crash", ctx do
    expect_installation_token(ctx, "ghs_err")

    Bypass.expect_once(ctx.bypass, "GET", "/repos/acme/app/issues/404", fn conn ->
      Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
    end)

    claims = claims_for(job(ctx, ["github_*"]))

    assert {:ok, %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}}} =
             Proxy.handle_rpc(
               "ana-bot",
               call("github_get_issue", %{"repository" => "acme/app", "number" => 404}),
               claims
             )

    assert %{"status" => 404} = Jason.decode!(text)
  end

  test "tools/list advertises the identity tools, filtered by capabilities", ctx do
    claims = claims_for(job(ctx, ["github_comment"]))

    assert {:ok, %{"result" => %{"tools" => [%{"name" => "github_comment"}]}}} =
             Proxy.handle_rpc(
               "ana-bot",
               %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"},
               claims
             )
  end

  test "an environment without the capability cannot call the identity tools", ctx do
    claims = claims_for(job(ctx, []))

    assert {:error, %{message: "tool_denied"}} =
             Proxy.handle_rpc(
               "ana-bot",
               call("github_comment", %{"repository" => "acme/app", "number" => 1, "body" => "x"}),
               claims
             )
  end

  test "a job whose preset wears nothing never reaches the broker", ctx do
    {job, _attempt} =
      job_fixture(ctx.user, ctx.token, %{
        status: "running",
        admitted_environment: %{
          "name" => "plain",
          "capabilities" => ["*"],
          "preset" => %{"identities" => []}
        }
      })

    assert {:error, %{message: "unknown_mcp_server"}} =
             Proxy.handle_rpc("ana-bot", call("github_get_issue", %{}), claims_for(job))
  end

  test "an identity the house no longer declares, or now declares differently, is refused", ctx do
    claims = claims_for(job(ctx, ["github_*"]))
    rpc = call("github_get_issue", %{"repository" => "acme/app", "number" => 1})

    :ok =
      Config.load_map!(put_in(house(), ["identities", "ana-bot", "app_id"], "777"),
        path: Path.join(ctx.root, "omashiki.toml")
      )

    assert {:error, %{message: "identity_changed"}} = Proxy.handle_rpc("ana-bot", rpc, claims)

    :ok =
      Config.load_map!(
        house()
        |> Map.delete("identities")
        |> update_in(["presets", "reviewer"], &Map.delete(&1, "identities")),
        path: Path.join(ctx.root, "omashiki.toml")
      )

    assert {:error, %{message: "identity_unavailable"}} = Proxy.handle_rpc("ana-bot", rpc, claims)
  end

  test "invalid arguments are rejected before GitHub is contacted", ctx do
    claims = claims_for(job(ctx, ["github_*"]))

    assert {:error, %{message: "invalid_params"}} =
             Proxy.handle_rpc(
               "ana-bot",
               call("github_comment", %{"repository" => "../etc", "number" => 1, "body" => "x"}),
               claims
             )

    assert {:error, %{message: "unknown_tool"}} =
             Proxy.handle_rpc("ana-bot", call("github_delete_repo", %{}), claims)
  end

  test "the sandbox MCP config lists the identity as a proxied server", ctx do
    environment = job(ctx, ["github_*"]).admitted_environment

    assert McpConfig.server_names(environment) == ["ana-bot"]

    assert %{"mcp" => %{"ana-bot" => %{"url" => url, "headers" => %{"Authorization" => _}}}} =
             McpConfig.render(environment, %{}, %{token: "t", base_url: "http://house:4010"})

    assert url == "http://house:4010/api/v1/tools-proxy/ana-bot"
  end

  defp expect_installation_token(ctx, token) do
    Bypass.expect_once(ctx.bypass, "POST", "/app/installations/987654/access_tokens", fn conn ->
      ["Bearer " <> jwt] = Plug.Conn.get_req_header(conn, "authorization")
      [header, payload, signature] = String.split(jwt, ".")

      assert :public_key.verify(
               header <> "." <> payload,
               :sha256,
               Base.url_decode64!(signature, padding: false),
               ctx.public_key
             )

      assert %{"iss" => "123456"} = Jason.decode!(Base.url_decode64!(payload, padding: false))

      expires = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
      Plug.Conn.resp(conn, 201, Jason.encode!(%{"token" => token, "expires_at" => expires}))
    end)
  end

  defp job(ctx, capabilities) do
    {job, _attempt} =
      job_fixture(ctx.user, ctx.token, %{
        status: "running",
        admitted_environment: %{
          "name" => "review",
          "capabilities" => capabilities,
          "preset" => %{"name" => "reviewer", "identities" => [@public]}
        }
      })

    job
  end

  defp claims_for(job) do
    {:ok, token} = Claims.issue("tools", job, %{})
    {:ok, claims} = Claims.verify("tools", token)
    claims
  end

  defp call(tool, arguments) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => tool, "arguments" => arguments}
    }
  end

  defp house do
    %{
      "repositories" => %{"app" => %{"path" => "repo", "base_branch" => "main"}},
      "identities" => %{
        "ana-bot" => %{
          "kind" => "github-app",
          "app_id" => "123456",
          "installation_id" => "987654",
          "private_key" => "${env:#{@env_var}}"
        }
      },
      "presets" => %{"reviewer" => %{"plugin" => "opencode", "identities" => ["ana-bot"]}},
      "runtimes" => %{
        "docker" => %{
          "runc" => %{"debian" => %{"images" => %{"opencode" => "omashiki/agent:latest"}}}
        }
      },
      "environments" => %{
        "review" => %{
          "runtime" => "docker.runc.debian",
          "sink" => "git",
          "packages" => [],
          "preset" => "reviewer",
          "executables" => ["git"],
          "credentials" => [],
          "capabilities" => ["github_*"],
          "timeout_ms" => 900_000,
          "mounts" => [],
          "pre_steps" => [],
          "post_steps" => [],
          "network" => "none",
          "resources" => %{"cpus" => 2.0, "memory" => "2GB", "pids" => 256}
        }
      }
    }
  end
end
