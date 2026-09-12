defmodule OmashikiWeb.FallbackController do
  @moduledoc "Translate controller `{:error, reason}` tuples into problem+json."

  use OmashikiWeb, :controller

  alias OmashikiWeb.Api.Problem

  def call(conn, {:error, reason}) do
    Problem.from_reason(conn, reason)
  end
end
