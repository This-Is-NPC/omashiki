defmodule OmashikiWeb.Api.AgentSkillController do
  use OmashikiWeb.Api.Controller

  @skill_path "priv/agent_skill/SKILL.md"

  tags(["meta"])

  operation(:show,
    summary: "Agent skill document",
    security: [],
    responses: %{
      200 =>
        {"Skill", "text/markdown",
         %OpenApiSpex.Schema{type: :string, description: "SKILL.md contents"}}
    }
  )

  def show(conn, _params) do
    base = base_url(conn)
    body = String.replace(skill_document(), "{{OMASHIKI_URL}}", base)

    conn
    |> put_resp_content_type("text/markdown")
    |> send_resp(200, body)
  end

  defp skill_document do
    Application.app_dir(:omashiki, @skill_path)
    |> File.read!()
  end

  defp base_url(conn) do
    conn
    |> Phoenix.Controller.current_url()
    |> URI.parse()
    |> Map.put(:path, nil)
    |> Map.put(:query, nil)
    |> Map.put(:fragment, nil)
    |> URI.to_string()
    |> String.trim_trailing("/")
  end
end
