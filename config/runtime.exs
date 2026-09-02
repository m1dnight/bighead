import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/mem0 start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
alias Mem0.Embedder.Ollama
alias Mem0.LLM.Anthropic
alias Mem0.LLM.OpenRouter
alias Mem0.LLM.Stub

if System.get_env("PHX_SERVER") do
  config :mem0, Mem0Web.Endpoint, server: true
end

# Which LLM adapter to use for extraction.
llm_adapter =
  case EnvGuard.optional(
         "MEM0_LLM_PROVIDER",
         {:enum, ["stub", "anthropic", "openrouter"]},
         "stub"
       ) do
    "anthropic" ->
      Anthropic

    "openrouter" ->
      OpenRouter

    "stub" ->
      Stub
  end

embedder_adapter =
  case EnvGuard.optional("MEM0_EMBEDDER_PROVIDER", {:enum, ["stub", "ollama"]}, "stub") do
    "ollama" -> Ollama
    "stub" -> Mem0.Embedder.Stub
  end

# Each provider's key is required only when that provider is selected. Making
# either unconditional would break the property the `stub` default exists for:
# a clean checkout with no `.env` and no key boots, and `mix test` passes.
llm_api_key =
  case llm_adapter do
    Anthropic -> EnvGuard.required("ANTHROPIC_API_KEY", :string, min_length: 1)
    OpenRouter -> EnvGuard.required("OPENROUTER_API_KEY", :string, min_length: 1)
    Stub -> nil
  end

# The endpoint and the model name are provider-shaped: OpenRouter speaks
# chat-completions at its own host and namespaces models as `vendor/model`,
# while Anthropic's Messages API takes the bare model id. The env vars
# override either; the defaults just have to be usable per provider — a
# single default here is a URL or a slug that is wrong for the other one.
{default_llm_base_url, default_llm_model} =
  case llm_adapter do
    OpenRouter -> {"https://openrouter.ai/api/v1/chat/completions", "anthropic/claude-opus-5"}
    _anthropic_or_stub -> {"https://api.anthropic.com/v1/messages", "claude-opus-5"}
  end

llm_settings = [
  base_url: EnvGuard.optional("MEM0_LLM_BASE_URL", :string, default_llm_base_url),
  model: EnvGuard.optional("MEM0_LLM_MODEL", :string, default_llm_model),
  max_tokens: EnvGuard.optional("MEM0_LLM_MAX_TOKENS", :integer, 16_000, min: 1),
  # Reasoning effort, OpenRouter's vocabulary; the Anthropic adapter has no
  # effort mechanism and ignores it. `nil` means "not sent" — the model's own
  # default stands — which is not the same request as an explicit `none`.
  effort:
    EnvGuard.optional(
      "MEM0_LLM_EFFORT",
      {:enum, ["max", "xhigh", "high", "medium", "low", "minimal", "none"]},
      nil
    ),
  api_key: llm_api_key
]

# `MEM0_EMBEDDING_DIMENSIONS` is not decoration: it is the width the `vector(N)`
# column will have to declare. A mismatch between the configured model and the
# migrated column is otherwise a runtime error at insert time; naming it here
# makes it a boot-time value that one place owns.
embedder_settings = [
  base_url: EnvGuard.optional("OLLAMA_BASE_URL", :string, "http://localhost:11434"),
  model: EnvGuard.optional("MEM0_EMBEDDING_MODEL", :string, "nomic-embed-text"),
  dimensions: EnvGuard.optional("MEM0_EMBEDDING_DIMENSIONS", :integer, 768, min: 1)
]

config :mem0, Mem0Web.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

config :mem0, :hook, default_user_id: EnvGuard.optional("MEM0_DEFAULT_USER_ID", :string, "local", min_length: 1)

if config_env() == :test do
  # `config/test.exs` pins both adapters at their stubs, and nothing here may
  # undo that — `runtime.exs` is evaluated last, so writing `:adapter` in this
  # branch is the one edit that could put a live provider behind `mix test`.
  # `mix test.live` still needs real credentials, so they land under separate
  # keys that only `@tag :live` tests read.
  config :mem0, :live_embedder, [{:adapter, Ollama} | embedder_settings]

  config :mem0, :live_llm, [
    {:adapter, Anthropic},
    {:api_key, System.get_env("ANTHROPIC_API_KEY")} | llm_settings
  ]
else
  config :mem0, :embedder, [{:adapter, embedder_adapter} | embedder_settings]
  config :mem0, :llm, [{:adapter, llm_adapter} | llm_settings]

  # See the redaction policy note in config/config.exs.
  config :mem0, :log_llm_payloads, EnvGuard.optional("MEM0_LOG_LLM_PAYLOADS", :boolean, false)
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :mem0, Mem0Web.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/mem0_web/router\.ex$"E,
        ~r"lib/mem0_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :mem0, Mem0.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  config :mem0, Mem0Web.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  config :mem0, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :mem0, Mem0Web.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :mem0, Mem0Web.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :mem0, Mem0.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
