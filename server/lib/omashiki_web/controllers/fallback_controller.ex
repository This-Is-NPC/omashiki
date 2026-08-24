defmodule OmashikiWeb.FallbackController do
  @moduledoc """
  Translates controller action results into valid `Plug.Conn` responses.
  Provides consistent JSON error shapes.
  """
  use OmashikiWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "invalid_request",
        message: "Request validation failed",
        details: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)
      }
    })
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "not_found", message: "Resource not found", details: %{}}})
  end

  def call(conn, {:error, {_kind, _reason}}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "invalid_request", message: "Request is invalid", details: %{}}})
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
