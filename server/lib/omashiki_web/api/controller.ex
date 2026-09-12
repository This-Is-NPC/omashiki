defmodule OmashikiWeb.Api.Controller do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      use OmashikiWeb, :controller
      use OpenApiSpex.ControllerSpecs

      plug OmashikiWeb.Plugs.RequireScope
      plug OpenApiSpex.Plug.CastAndValidate, render_error: OmashikiWeb.Api.CastErrorRenderer

      action_fallback OmashikiWeb.FallbackController

      alias OmashikiWeb.Api.Problem
      alias OmashikiWeb.ApiSpec.Schemas
    end
  end
end
