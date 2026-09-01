defmodule Mem0Web.Router do
  use Mem0Web, :router

  alias Plug.Swoosh.MailboxPreview

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Mem0Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", Mem0Web do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Bound to loopback in dev (see `config/dev.exs`), and that matters more now
  # than it will later: this accepts conversation transcripts and, until bearer
  # tokens land, no credentials at all. It should not be reachable off-box by
  # accident.
  scope "/hooks", Mem0Web do
    pipe_through :api

    post "/user-prompt-submit", HooksController, :user_prompt_submit
    post "/stop", HooksController, :stop
    post "/snapshot", HooksController, :snapshot

    # mem0's own, not Claude Code hook events. `lines-seen` is a read and takes
    # its scope from the query string; `backfill` writes.
    get "/lines-seen", HooksController, :lines_seen
    post "/backfill", HooksController, :backfill
  end

  # An operator's tool, not hook machinery: a whole session file as raw JSON
  # Lines, and the full write path — messages stored, facts extracted and
  # reconciled — runs in one request. Same no-credentials caveat as `/hooks`.
  scope "/", Mem0Web do
    pipe_through :api

    post "/transcripts", TranscriptController, :create
  end

  # Other scopes may use custom stacks.
  # scope "/api", Mem0Web do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:mem0, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: Mem0Web.Telemetry
      forward "/mailbox", MailboxPreview
    end
  end
end
