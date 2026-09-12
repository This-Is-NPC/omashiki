defmodule OmashikiWeb.Plugs.ApiRateLimit do
  @moduledoc "Per-token request rate limit on the authenticated API pipeline."

  @behaviour Plug

  alias Omashiki.ApiTokens.Token
  alias OmashikiWeb.Api.Problem
  alias OmashikiWeb.RateLimiter

  @max Application.compile_env(:omashiki, [:api_request_rate, :max], 120)
  @per_ms Application.compile_env(:omashiki, [:api_request_rate, :per_ms], 60_000)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case conn.assigns[:current_token] do
      %Token{id: id} ->
        case RateLimiter.hit("api", id, max: @max, per_ms: @per_ms) do
          {:ok, _count, _key} ->
            conn

          {:error, :rate_limited} ->
            Problem.halt(conn, "rate_limited", retry_after: div(@per_ms, 1000))
        end

      _ ->
        conn
    end
  end
end
