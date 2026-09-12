defmodule OmashikiWeb.ErrorJSON do
  @moduledoc """
  Phoenix JSON error renderer for unmatched routes and unhandled exceptions.

  Authenticated API errors use `OmashikiWeb.Api.Problem` instead.
  """

  alias OmashikiWeb.Api.Problem

  def render("404.json", assigns), do: problem(assigns, "not_found")

  def render(template, assigns) do
    case Integer.parse(String.replace_suffix(template, ".json", "")) do
      {status, ""} ->
        problem(assigns, "internal_error",
          status: status,
          title: Phoenix.Controller.status_message_from_template(template),
          detail: Phoenix.Controller.status_message_from_template(template)
        )

      _ ->
        problem(assigns, "internal_error")
    end
  end

  defp problem(assigns, code, opts \\ []) do
    conn = assigns[:conn]
    payload = Problem.body(conn, code, opts)
    Problem.assert_declared!(conn, payload.status)
    payload
  end
end
