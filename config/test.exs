import Config

alias Mem0.Embedder.Stub
alias Swoosh.Adapters.Test

# Print only warnings and errors during test
config :logger, level: :warning

# In test we don't send emails
# to provide built-in test partitioning in CI environment.
# Configure your database
# Run `mix help test` for more information.
#
# The MIX_TEST_PARTITION environment variable can be used

config :mem0, Mem0.Mailer, adapter: Test

config :mem0, Mem0.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "mem0_test#{System.get_env("MIX_TEST_PARTITION")}",
  # We don't run a server during test. If one is required,
  # you can enable the server option below.
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :mem0, Mem0Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "49T/GmlzBIVSwIRnLQ1UDyQecA0TwBFFEXS+WEoaIGPqj3Sp+86hZCm6KIHndTrh",
  server: false

# Tests must not hit the network or spend money, so both ports are pinned at
# their stubs here. `config/runtime.exs` is evaluated after this file and
# deliberately writes no `:adapter` under `MIX_ENV=test` — the live credentials
# it does read land under `:live_llm` / `:live_embedder`, which only `@tag :live`
# tests touch.
config :mem0, :embedder, adapter: Stub, dimensions: 768
config :mem0, :llm, adapter: Mem0.LLM.Stub, model: "stub-model", max_tokens: 1024

# Never log payloads under test, whatever the environment says.
# No background sweeps in test: the refresher would query the database on its
# own timer, outside any test's sandbox ownership. See `Mem0.Application`.
config :mem0, :log_llm_payloads, false
config :mem0, :start_refresher, false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false
