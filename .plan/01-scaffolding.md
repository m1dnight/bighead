# Phase 1 — Scaffolding

**Goal:** a clean checkout can run `docker compose up -d && mix setup && mix precommit` and get a
green result, CI runs the same checks on every push, and the release image builds and migrates.
No domain code whatsoever.

> Every command, version and file list below was executed or fetched against the real toolchain,
> a real `pgvector/pgvector:pg18` container and a real `docker build`. Where a claim is a judgement
> call rather than a verified fact, it says so.

## Starting point

Generated Phoenix 1.8.9 app, Elixir 1.20.2 / OTP 29.0.3, Ecto+Postgrex, LiveView, Tailwind/esbuild,
`precommit` alias running compile + format + test. Missing: a vector store, a database that runs,
static analysis, CI, a release image.

Three environment facts that shape this phase:

- **Local Postgres is not running and has no `vector` extension.** `pg_isready` fails on :5432 and
  the Homebrew PostgreSQL 18.3 install ships no `vector.control`. The dev database must come from a
  container.
- **`mix.exs` already sets `cli/0 → preferred_envs: [precommit: :test]`.** This constrains which
  envs every dep in the `precommit` alias must be available in — see 1.6. It is the single most
  likely thing to break here.
- **`/bighead/` is the upstream Python clone** (100 MB) and is gitignored. Keep it — it is the
  reference implementation. But it must be kept out of the Docker build context (1.5).

---

## 1.1 Pin the toolchain

There are currently three potential sources of truth for the Elixir/OTP version: `mix.exs`
(`elixir: "~> 1.17"`), the generated Dockerfile's own `ELIXIR_VERSION`/`OTP_VERSION` args (1.5),
and CI (1.8). Reconcile them before anything else.

- Add `.tool-versions`: `elixir 1.20.2-otp-29`, `erlang 29.0.3`
- Bump `mix.exs` to `elixir: "~> 1.20"`

## 1.2 Dev/test database with pgvector

`docker-compose.yml` at the repo root:

```yaml
services:
  db:
    image: pgvector/pgvector:pg18
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: bighead_dev
    ports: ["5432:5432"]
    volumes: [bighead_pgdata:/var/lib/postgresql/data]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 10

volumes:
  bighead_pgdata:
```

Verified: the tag exists and gives PostgreSQL 18.6 with pgvector 0.8.6 available. The credentials in
`config/dev.exs` and `config/test.exs` already match, so no config change is needed.

**Two caveats, both real:**

- **`pg18` pins the Postgres major, not the pgvector version.** The tag is rebuilt over time, so
  "dev and CI agree on the extension version" only holds if the image is pinned by digest. Pin it
  in both compose and CI if that matters; otherwise state explicitly that it doesn't.
- **The Postgres major is a deployment decision, not a local-convenience one.** pg18 narrows the
  set of managed Postgres offerings, and 1.5 already forces the deployment conversation because of
  `CREATE EXTENSION`. Choose the major from the target, not from the local `psql` version.

## 1.3 pgvector, extensions, and timestamp precision

Add `{:pgvector, "~> 0.4"}` (resolves to 0.4.0).

`lib/bighead/postgrex_types.ex`:

```elixir
Postgrex.Types.define(
  Bighead.PostgrexTypes,
  Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions(),
  []
)
```

Use `Pgvector.extensions()` — **not** a hand-written `[Pgvector.Extensions.Vector]`. The helper was
added in pgvector 0.3.0 and returns `Vector`, `Halfvec` and `Sparsevec`. Listing only `Vector`
compiles and works, then fails at runtime with `type 'halfvec' can not be handled by the types
module` the moment a halfvec column appears — and halfvec is the standard choice above 2000
dimensions (see below).

The file has no `defmodule`; it defines the module as a compile-time side effect. That is the
documented pattern, it needs no special elixirc handling, and the `.beam` is produced normally.

Then `config/config.exs`:

```elixir
config :bighead, Bighead.Repo, types: Bighead.PostgrexTypes
```

This merges with, rather than replaces, the per-env repo config.

### The extension migration

Enable **all three** extensions in one migration, generated with `mix ecto.gen.migration` as
AGENTS.md requires:

```elixir
def up do
  execute("CREATE EXTENSION IF NOT EXISTS vector")
  execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")
  execute("CREATE EXTENSION IF NOT EXISTS unaccent")
end
```

`pg_trgm` and `unaccent` are for the lexical retrieval channel, several phases away. They are here
because `CREATE EXTENSION` requires superuser on most managed Postgres, and discovering that a
second time in a later phase means re-opening the deployment question then. Learn the whole
permission surface once, now.

**Constraint to write down and keep:** this migration must stand alone. Postgrex resolves type OIDs
when a connection opens, and the connection running migrations opens *before* `CREATE EXTENSION
vector` executes. So no migration may bind a `vector` parameter in the same `mix ecto.migrate` run
that creates the extension. Harmless today; an opaque failure the first time a later migration
backfills or seeds an embedding.

### Timestamp precision

`config/config.exs` currently has `generators: [timestamp_type: :utc_datetime]`, which truncates to
whole seconds. Change it to `:utc_datetime_usec`.

This is a one-line change now and a migration across every table later. It matters more here than
in a normal app: ingestion is per message pair, and keeping the three clocks distinct is the whole
point of the temporal design. Two pairs ingested in the same second would get identical `inserted_at`,
which breaks recency-ordered conflict resolution and supersession ordering.

### Exit check

A round-trip test — and run it through `Bighead.DataCase, async: true`, not a bare `Repo.query`, so it
exercises the sandbox path every later test will use:

```elixir
test "vector type round-trips" do
  v = Pgvector.new([1.0, 2.0, 3.0])
  assert {:ok, %{rows: [[^v]]}} = Repo.query("SELECT $1::vector", [v])
end
```

Verified to pass and to return an actual `%Pgvector{}` in `rows`.

*(An earlier draft justified this test by claiming the types wiring "fails silently". It does not —
removing the `types:` config raises `type 'vector' can not be handled by the types module
Postgrex.DefaultTypes` immediately and clearly. The test is still worth having as a wiring check;
the scary rationale was wrong.)*

**Carried to the embedder decision:** pgvector's HNSW and IVFFlat indexes cap at **2000 dimensions**
for `vector`. A 3072-dim model cannot be indexed as `vector(3072)` — it needs `halfvec`. That
ceiling belongs in the Phase 3 open question, not discovered at index-creation time.

## 1.4 Config plumbing for secrets, test defaults, and telemetry

Small, and the reason it is in Phase 1 rather than Phase 3 is that all three are expensive to
retrofit once several phases of code assume their absence.

**Secrets.** `config/runtime.exs` currently reads only `DATABASE_URL` and `SECRET_KEY_BASE`, and
`.gitignore` has no `.env` entry. The first LLM adapter arrives in Phase 3 and someone will create
a `.env` in a repo that does not ignore it.

- Add `.env` and `.env.*` (excluding `.env.example`) to `.gitignore`; commit a `.env.example`
- Decide the loading mechanism now — `dotenvy` in `runtime.exs`, or direnv. Either is fine; having
  two is not
- Add empty `config :bighead, :llm, ...` / `config :bighead, :embedder, ...` runtime blocks reading
  `System.get_env/1`, so Phase 3 fills in values instead of restructuring config

**Tests must not hit the network or spend money.** The plan's argument for building ports before
pipelines depends on this, and nothing currently enforces it.

- `config/test.exs`: point `:llm` and `:embedder` at `Bighead.LLM.Stub` / `Bighead.Embedder.Stub`. The
  config keys can exist before the modules do
- `test/test_helper.exs`: `ExUnit.configure(exclude: [:live])`, plus a `test.live` alias

**Telemetry namespace.** The metrics that will matter — LLM latency, token counts, cost, embedding
volume, vector-search latency — are all produced by code written in later phases. If the convention
doesn't exist first, each phase invents its own and they get normalised later.

- Document `[:bighead, :llm | :embedder | :ingest | :search, :start | :stop | :exception]` in
  `BigheadWeb.Telemetry` as placeholder metric definitions
- Enable `Telemetry.Metrics.ConsoleReporter` in dev
- **Decide the redaction policy now:** memory contents are user data and prompts are exactly what
  you most want to log when debugging. Decide before debug logging is scattered across four phases

## 1.5 Release and Docker image

```
mix phx.gen.release --docker
```

Verified output — note this is **more** than a Dockerfile:

```
Dockerfile
.dockerignore
lib/bighead/release.ex
rel/overlays/bin/server      rel/overlays/bin/server.bat
rel/overlays/bin/migrate     rel/overlays/bin/migrate.bat
```

`lib/bighead/release.ex` is real `lib/` code (it is what `bin/migrate` calls via
`eval Bighead.Release.migrate`) and is therefore subject to format/credo/dialyzer — which is why this
step runs **before** the formatting sweep in 1.6, not after.

It does **not** generate `rel/env.sh.eex` or `rel/vm.args.eex` (those come from `mix release.init`),
and it does **not** modify `mix.exs` — no `releases:` config is required.

Verified: `docker build .` succeeds as generated, including the `heroicons`/`daisyui` GitHub deps
(the builder stage installs `git`), `mix assets.deploy` runs, and the image serves HTTP 200 on `/`.

**Two edits immediately after the generator, in the same step:**

1. **`.dockerignore` is a deny-list and knows nothing about this repo.** It excludes `/test/`,
   `/deps/`, `/_build/` and friends, but not `/bighead/` (100 MB Python clone), `/.expert/` (29 MB),
   `/.plan/` or `/docs/`. Add them, or every `docker build .` ships them into the build context.
2. **Reconcile the Dockerfile's pinned `ELIXIR_VERSION`/`OTP_VERSION`/`DEBIAN` args** with
   `.tool-versions` from 1.1.

**Deployment caveat to record in the README:** `rel/overlays/bin/migrate` runs the 1.3 extension
migration, which needs superuser or pre-installed trusted extensions on the target. Managed
Postgres offerings vary in whether `vector` is available at all.

## 1.6 Static analysis: Credo, Quokka, Dialyzer

```elixir
{:quokka, "~> 2.13", only: [:dev, :test], runtime: false},
{:credo, "~> 1.7", only: [:dev, :test], runtime: false},
{:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
```

`dialyxir` must include `:test`. `preferred_envs: [precommit: :test]` means anything reachable from
`precommit` — or from a CI run with `MIX_ENV=test` — has to exist in `:test`. With `only: [:dev]`
the result is a flat `** (Mix) The task "dialyzer" could not be found`.

**`.credo.exs` must be generated first**, because Quokka reads it to decide which style rules to
enforce (`Credo.ConfigFile.read_or_default/2`):

```
mix credo.gen.config
```

This writes ~221 lines. Trim it to the rules actually being enforced rather than committing the
whole checklist — and note one non-obvious consequence: Quokka inherits
`Credo.Check.Readability.MaxLineLength, max_length: 120` from that file, silently raising the
effective line length from Elixir's default 98.

Then add Quokka to `.formatter.exs` plugins:

```elixir
plugins: [Quokka, Phoenix.LiveView.HTMLFormatter],
```

*(Order within the list does not matter, contrary to an earlier draft. `Quokka.features/1` claims
`.ex`/`.exs` with no sigils; the LiveView formatter claims `.heex` and `~H`. They never compete —
formatting the same tree in both orders produced byte-identical output. Only the "`.credo.exs`
first" half of that claim was correct.)*

### The formatting sweep — and Quokka's non-convergence

Quokka is a rewriter, not a linter. On generated Phoenix code the first run produces a large diff.
**Do it as its own commit, after 1.5, before any domain code.** Otherwise every later diff is half
real work and half style churn.

Two verified traps:

- **Quokka is not a one-pass fixed point.** On `test/support/conn_case.ex`, pass 1 reorders the
  `use`/`import` block and pass 2 then inserts a blank line. `--check-formatted` fails after one
  pass and succeeds after two.
- **Bare `mix format` uses a timestamp cache** and will skip files whose mtime predates the format
  manifest — four consecutive bare runs left `--check-formatted` failing. `mix format --force`, or
  naming the file explicitly, bypasses it.

So: run `mix format --force` repeatedly in the sweep commit until `mix format --check-formatted`
exits 0, and use `--force` in `precommit` (1.7).

### Credo will not pass on generated code — budget for it

Measured on the actual repo with a freshly generated `.credo.exs`:

- Before Quokka: `mix credo --strict` → exit 6, four findings —
  `Design.AliasUsage` at `lib/bighead_web/components/core_components.ex:211` and
  `test/support/data_case.ex:39,40`; `Readability.AliasOrder` at `lib/bighead_web.ex:91`.
- After Quokka: still exit 2. Quokka fixes the `AliasOrder` and `core_components` findings but
  **not** the `Ecto.Adapters.SQL.Sandbox` usages in `test/support/data_case.ex`.

So "format then credo is clean" is false out of the box. Fix it explicitly: either alias `Sandbox`
in `data_case.ex` (two call sites, trivial) or disable `Design.AliasUsage`. Recommend aliasing —
`Design.AliasUsage` is a contentious check but the generated code is the only thing tripping it.

### Dialyzer

```elixir
dialyzer: [
  plt_local_path: "priv/plts",
  plt_core_path: "priv/plts",
  plt_add_apps: [:mix, :ex_unit],
  flags: [:error_handling, :extra_return, :missing_return]
]
```

Verified correct and clean (`Total errors: 0`) against this project. Add `/priv/plts/` to
`.gitignore` **before** the first run, not after.

`:underspecs` stays off — noisy on generated code, and only worth it once a real functional core
exists. **Dialyzer runs in CI only, not in `precommit`** (see 1.7): with zero domain code it finds
nothing and adds minutes to the loop AGENTS.md tells every agent to run constantly. Revisit putting
it back in `precommit` at Phase 3, when the port behaviours land and specs start carrying weight.

## 1.7 The `precommit` alias

```elixir
precommit: [
  "compile --warnings-as-errors",
  "deps.unlock --unused",
  "format --force",
  "credo --strict",
  "test"
]
```

- `format` rewrites rather than checks, because locally you want it fixed. `--force` for the cache
  reason in 1.6.
- `format` runs before `credo` because Quokka resolves most of what Credo would report — running
  Credo first just produces findings the next step erases.
- No `dialyzer` (1.6).

CI does the opposite and **must not call `precommit`**: a step that mutates the working tree can
green-light code that a fresh checkout would reject.

**Known residual divergence:** `precommit` can pass while CI step 3 fails, if Quokka fails to
converge on newly written code. If that happens, run `mix format --force` twice. Worth a
`git diff --exit-code` pre-push guard if it turns out to bite more than once.

## 1.8 GitHub Actions

`.github/workflows/ci.yml`, triggered on `push` and `pull_request`.

**Job 1 — checks.** `MIX_ENV: test` at the workflow level, so the tree is compiled once rather than
once for dev checks and again for `mix test`, and so `--warnings-as-errors` actually covers
`test/support/`. This is the other reason dialyxir needs `:test` in 1.6.

- Service container: `pgvector/pgvector:pg18` with `POSTGRES_PASSWORD: postgres` and a `pg_isready`
  health check — same image as compose
- `erlef/setup-beam@v1` with `otp-version: "29.0.3"`, `elixir-version: "1.20.2"`,
  **`version-type: strict`**. Without `strict`, setup-beam defaults to `loose` and resolves `"29"`
  to the newest 29.x on builds.hex.pm — which is `29.0.5` today against 29.0.3 locally, defeating
  the entire point of pinning
- Two caches: `deps/` + `_build/` keyed on `hash(mix.lock)`, and `priv/plts/` keyed separately.
  The PLT cache is the important one — minutes per run, invalidating on a different schedule
- Steps: `mix deps.get --check-locked` → `mix deps.unlock --check-unused` →
  `mix format --check-formatted` → `mix compile --warnings-as-errors` → `mix credo --strict` →
  `mix dialyzer --format github` → `mix test --warnings-as-errors`

`--check-locked` catches a lockfile that doesn't satisfy `mix.exs`; `--check-unused` catches stale
entries. They are different failures and both are cheap. Verified: `format --check-formatted` before
`compile --warnings-as-errors` does not mask compiler warnings.

**Job 2 — image.** `docker build .`, then run the image's `bin/migrate` against a pgvector service
container. Without this the Dockerfile — and `mix assets.deploy`, which only runs inside it — will
be broken by Phase 3 and nobody will notice until Phase 8. The migrate step is the one that
actually exercises the `CREATE EXTENSION` permission question from 1.5. If wiring the container to
the service network proves fiddly, keep the build and drop the migrate; do not drop both.

## 1.9 AGENTS.md and housekeeping

**Update `AGENTS.md` in the same commit as the `precommit` change.** It is the file that governs
every future agent session, its first instruction is to run `mix precommit`, and this phase changes
three things it doesn't know about:

1. `docker compose up -d` is now a hard prerequisite for anything touching the database
2. What `precommit` contains and, notably, that it no longer runs dialyzer
3. Quokka silently rewrites whatever gets written — alias order, pipelines, directive order

Also:

- Track `.plan/` in git — documentation, not scratch
- Leave the generated web layer and swoosh in place; later phases use the web layer for the REST
  API and a LiveView memory inspector

---

## Exit criteria

- [ ] `docker compose up -d` yields a Postgres with `vector`, `pg_trgm` and `unaccent` available
- [ ] `mix setup` succeeds from clean `deps/` and `_build/`
- [ ] `docker compose down -v && docker compose up -d && mix ecto.reset` succeeds — the from-zero
      path, which is the one the extension-ordering constraint in 1.3 threatens
- [ ] The vector round-trip test passes under `Bighead.DataCase, async: true`
- [ ] `mix precommit` is green, **and** `mix format --check-formatted` and `git diff --exit-code`
      are clean immediately after it
- [ ] `mix dialyzer` reports zero warnings with no `ignore_warnings` file
- [ ] Both CI jobs green on a pull request, with all three caches hitting on a second run
- [ ] `mix test` passes with no network access and no API key set
- [ ] AGENTS.md reflects the DB prerequisite, the new `precommit`, and Quokka

## Explicitly out of scope

No domain structs, no schemas beyond the extension migration, no LLM or embedder implementations,
no prompts. Config *keys* for the LLM and embedder exist; values do not.
