defmodule OmashikiWeb.ErrorJSON do
  @moduledoc """
  Phoenix JSON error renderer for unmatched routes and unhandled exceptions.

  Authenticated API errors use `OmashikiWeb.Api.Problem` instead.
  """

  alias OmashikiWeb.Api.Problem

  def render("404.json", assigns), do: Problem.body(assigns[:conn], "not_found")

  def render(template, assigns) do
    status =
      template
      |> String.replace_suffix(".json", "")
      |> String.to_integer()

    Problem.body(assigns[:conn], "internal_error",
      status: status,
      title: Phoenix.Controller.status_message_from_template(template),
      detail: Phoenix.Controller.status_message_from_template(template)
    )
  rescue
    _ ->
      Problem.body(assigns[:conn], "internal_error")
  end
end
