defmodule OmashikiWeb.Plugs.RequireScope do
  @moduledoc """
  Deny a bearer token that lacks the scopes declared on the OpenAPI operation.
  Operator sessions and local auth-none have every scope.
  """

  @behaviour Plug

  alias Omashiki.ApiTokens.Token
  alias OmashikiWeb.Api.Problem

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case required_scopes(conn) do
      [] ->
        conn

      scopes ->
        case conn.assigns[:current_token] do
          nil ->
            conn

          %Token{scopes: held} ->
            if Enum.all?(scopes, &(&1 in held)) do
              conn
            else
              Problem.halt(conn, "insufficient_scope",
                errors: [%{field: "scopes", code: "insufficient_scope", required: scopes}]
              )
            end
        end
    end
  end

  defp required_scopes(conn) do
    controller = conn.private[:phoenix_controller]
    action = conn.private[:phoenix_action]

    operation =
      if is_atom(controller) and is_atom(action) and
           function_exported?(controller, :open_api_operation, 1) do
        controller.open_api_operation(action)
      end

    case operation do
      %{security: security} when is_list(security) ->
        security
        |> Enum.flat_map(fn
          %{"bearer" => scopes} when is_list(scopes) -> scopes
          %{bearer: scopes} when is_list(scopes) -> scopes
          _ -> []
        end)
        |> Enum.uniq()

      _ ->
        []
    end
  end
end
