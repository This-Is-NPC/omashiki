defmodule OmashikiWeb.Api.CastErrorRenderer do
  @moduledoc "Render OpenApiSpex cast failures as RFC 9457 problem+json."

  @behaviour Plug

  alias OmashikiWeb.Api.Problem

  @impl Plug
  def init(errors), do: errors

  @impl Plug
  def call(conn, errors) when is_list(errors) do
    Problem.send(conn, "invalid_request", errors: Enum.map(errors, &to_error/1))
  end

  def call(conn, reason), do: call(conn, List.wrap(reason))

  defp to_error(%OpenApiSpex.Cast.Error{} = error) do
    %{
      field: OpenApiSpex.path_to_string(error),
      code: reason_code(error.reason)
    }
  end

  defp to_error(other), do: %{field: "$", code: "invalid", detail: inspect(other)}

  defp reason_code(:missing_field), do: "required"
  defp reason_code(:unexpected_field), do: "unknown_field"
  defp reason_code(:invalid_type), do: "invalid_type"
  defp reason_code(:invalid_enum), do: "invalid_enum"
  defp reason_code(:invalid_format), do: "invalid_format"
  defp reason_code(:max_length), do: "too_large"
  defp reason_code(:min_length), do: "blank"
  defp reason_code(:max_items), do: "too_large"
  defp reason_code(:min_items), do: "must_not_be_empty"
  defp reason_code(:maximum), do: "too_large"
  defp reason_code(:minimum), do: "too_small"
  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code(reason), do: inspect(reason)
end
