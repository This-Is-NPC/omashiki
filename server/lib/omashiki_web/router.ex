defmodule OmashikiWeb.Router do
  use OmashikiWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {OmashikiWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json", "event-stream"]
  end

  pipeline :authenticated_api do
    plug :accepts, ["json", "event-stream"]
    plug :fetch_session
    plug OmashikiWeb.Plugs.BearerAuth
  end

  scope "/", OmashikiWeb do
    pipe_through :browser

    get "/signup", UserController, :new_signup
    post "/signup", UserController, :create_signup
    get "/login", UserController, :new_session
    post "/login", UserController, :create_session
    delete "/logout", UserController, :delete_session
  end

  scope "/", OmashikiWeb do
    pipe_through :browser

    live_session :authenticated, on_mount: {OmashikiWeb.AuthHooks, :require_user} do
      live "/", OverviewLive, :index
      live "/queue", QueueLive, :index
      live "/jobs/:id", JobLive, :show
      live "/config", ConfigLive, :index
    end
  end

  # Health and token issuance are the only unauthenticated control-plane
  # surfaces. All queue reads and mutations require an authenticated actor.
  scope "/api/v1", OmashikiWeb.Api, as: :api do
    pipe_through :api

    get "/health", HealthController, :show
    post "/sessions/issue_token", SessionsController, :issue_token
    post "/sessions/signup", SessionsController, :signup
  end

  scope "/api/v1", OmashikiWeb.Api, as: :api do
    pipe_through :authenticated_api

    # Registry discovery is read-only and intentionally omits host paths,
    # credentials, mounts, and other execution internals.
    get "/repositories", DiscoveryController, :repositories
    get "/environments", DiscoveryController, :environments

    # Admission and queue lifecycle.
    post "/jobs", JobsController, :create
    post "/jobs/batch", JobsController, :batch
    get "/jobs", JobsController, :index
    get "/jobs/:id/events/history", JobsController, :events
    get "/jobs/:id/events", JobEventsController, :stream
    get "/jobs/:id/events/stream", JobEventsController, :stream
    get "/jobs/:id/result", JobsController, :result
    post "/jobs/:id/cancel", JobsController, :cancel
    post "/jobs/:id/retry", JobsController, :retry
    get "/jobs/:id/webhook-deliveries", WebhookDeliveriesController, :index
    get "/jobs/:id", JobsController, :show
  end

  # Runtime containers reach only the signed internal tool proxy.
  scope "/api/v1", OmashikiWeb.Api, as: :api do
    pipe_through :api

    post "/tools-proxy/:server", ToolsProxyController, :handle

    # LLM ingress for agent containers. Not `:authenticated_api`: the Bearer
    # here is a job-bound gateway token minted at provision time, which
    # GatewayController verifies itself — an operator API token would be the
    # wrong credential.
    post "/gateway/v1/chat/completions", GatewayController, :chat_completions
  end
end
