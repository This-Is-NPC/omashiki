defmodule OmashikiWeb.ErrorJSON do
  @moduledoc """
  Phoenix JSON error renderer for unmatched routes and unhandled exceptions.

  Authenticated API errors use `OmashikiWeb.Api.Problem` instead.
  """

  def render("404.json", _assigns) do
    %{
      type: "about:blank",
      title: "Resource not found",
      status: 404,
      code: "not_found",
      detail: "Resource not found",
      errors: [],
      request_id: nil
    }
  end

  def render(template, _assigns) do
    status = String.replace_suffix(template, ".json", "")

    %{
      type: "about:blank",
      title: Phoenix.Controller.status_message_from_template(template),
      status: String.to_integer(status),
      code: "internal_error",
      detail: Phoenix.Controller.status_message_from_template(template),
      errors: [],
      request_id: nil
    }
  rescue
    _ ->
      %{
        type: "about:blank",
        title: "Request could not be completed",
        status: 500,
        code: "internal_error",
        detail: "Request could not be completed",
        errors: [],
        request_id: nil
      }
  end
end
