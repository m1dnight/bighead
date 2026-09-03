defmodule BigheadWeb.Router do
  use BigheadWeb, :router

  alias OpenApiSpex.Plug.PutApiSpec
  alias OpenApiSpex.Plug.RenderSpec
  alias Plug.Swoosh.MailboxPreview

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BigheadWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug PutApiSpec, module: BigheadWeb.ApiSpec
  end

  scope "/", BigheadWeb do
    pipe_through :browser

    get "/", PageController, :home

    live "/projects", ProjectLive.Index, :index
    live "/projects/:user", ProjectLive.Show, :show

    live "/conversations", ConversationLive.Index, :index
    live "/conversations/:session", ConversationLive.Show, :show
  end

  # `/transcripts` is capture: the hook script posts the whole session
  # transcript there on `Stop` and `SessionEnd`, and an operator posts there
  # to backfill a file by hand. No credentials on either route.
  scope "/v1", BigheadWeb do
    pipe_through :api

    post "/transcripts", TranscriptController, :create
    post "/diffs", DiffController, :create

    # `/recall` is the read side: the hook posts the user's prompt here on
    # `UserPromptSubmit` and injects the facts that come back as context.
    post "/recall", RecallController, :create
  end

  # The spec route sits outside the `BigheadWeb` scope: `RenderSpec` is a plug
  # from `open_api_spex`, not one of our controllers.
  scope "/v1" do
    pipe_through :api

    get "/openapi", RenderSpec, []
  end

  # Other scopes may use custom stacks.
  # scope "/api", BigheadWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:bighead, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: BigheadWeb.Telemetry
      forward "/mailbox", MailboxPreview
    end
  end
end
