# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

alias Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  bighead: [
    args: ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :bighead, Bighead.Mailer, adapter: Local

# Merges with the per-environment repo config below. `Bighead.PostgrexTypes` is
# defined in lib/bighead/postgrex_types.ex and teaches Postgrex the pgvector types.
config :bighead, Bighead.Repo, types: Bighead.PostgrexTypes

# Configure the endpoint
config :bighead, BigheadWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BigheadWeb.ErrorHTML, json: BigheadWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Bighead.PubSub,
  live_view: [signing_salt: "NcYZrUYX"]

# Placeholders only. `config/runtime.exs` fills these from the environment for
# dev and prod, and `config/test.exs` pins the adapters at stubs. They are
# declared here so that every environment sees the same key set and a missing
# key is a `KeyError` naming the setting rather than a silent `nil`.
config :bighead, :embedder, adapter: nil, base_url: nil, model: nil, dimensions: nil
# the default user id for a user. We will not support users right now, so all the same.
config :bighead, :hook, default_user_id: "local"
config :bighead, :llm, adapter: nil, model: nil, max_tokens: nil, api_key: nil

# --- Redaction policy ---
#
# Memory contents are user data and prompts are exactly what you most want to
# log when debugging, so the default is that neither reaches a log line or a
# telemetry measurement. Telemetry events carry metadata only: latency, token
# counts, model name, operation counts.
#
# Set this to `true` (or `BIGHEAD_LOG_LLM_PAYLOADS=true` at runtime) to include
# prompts and completions in `:debug` logs. It is intended for local debugging
# against throwaway data and should never be true where real memories live.
config :bighead, :log_llm_payloads, false

config :bighead,
  ecto_repos: [Bighead.Repo],
  generators: [timestamp_type: :utc_datetime_usec]

# Phoenix's own request logger prints `Parameters: %{...}` for every request, so
# without this the transcript reaches the log through the router whatever bighead
# itself logs. These keys cover both hook bodies: the spliced transcript, the
# prompt, and the answer that rides along on `Stop`.
#
# `config/dev.exs` deliberately sets this back to `[]`. Dev is where you are
# reading payloads on purpose, and it is imported after this file so it wins.
# Every other environment keeps the filter.
config :phoenix,
       :filter_parameters,
       ~w(password entries prompt content message last_assistant_message)

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  bighead: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    # Import environment specific config. This must remain at the bottom
    # of this file so it overrides the configuration defined above.
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

import_config "#{config_env()}.exs"
