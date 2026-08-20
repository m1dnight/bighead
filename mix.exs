defmodule Mem0.MixProject do
  use Mix.Project

  def project do
    [
      app: :mem0,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: dialyzer()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Mem0.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Dialyzer runs in CI only, not in `precommit` — see the `precommit` alias
  # below. `:underspecs` stays off: it is noisy on generated code and only
  # starts earning its keep once the Phase 3 port behaviours land.
  defp dialyzer do
    [
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      plt_add_apps: [:mix, :ex_unit],
      flags: [:error_handling, :extra_return, :missing_return]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:pgvector, "~> 0.4"},

      # Static analysis. All three must include `:test`: `cli/0` below sets
      # `preferred_envs: [precommit: :test]`, so anything reachable from
      # `precommit` — or from a CI run with `MIX_ENV=test` — has to exist in
      # `:test` or the task simply cannot be found.
      {:quokka, "~> 2.13", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      # `:live` tests are excluded by default in test/test_helper.exs because
      # they talk to real APIs and cost money. This is the way to run them.
      "test.live": ["ecto.create --quiet", "ecto.migrate --quiet", "test --include live"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind mem0", "esbuild mem0"],
      "assets.deploy": [
        "tailwind mem0 --minify",
        "esbuild mem0 --minify",
        "phx.digest"
      ],
      # `format` rewrites rather than checks, because locally you want it fixed,
      # and it runs before `credo` because Quokka resolves most of what Credo
      # would otherwise report. `--force` bypasses the format task's timestamp
      # cache, which will otherwise skip files whose mtime predates the format
      # manifest and leave `--check-formatted` failing.
      #
      # No `dialyzer` here — see the `dialyzer/0` note above. CI runs it.
      # CI must NOT call this alias: a step that mutates the working tree can
      # green-light code that a fresh checkout would reject.
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --force",
        "credo --strict",
        "test"
      ]
    ]
  end
end
