# Phase 3 — Ports

**Goal:** the application can read its configuration from the environment, and can make a real call
to a real language model and a real embedder — through a behaviour, with a stub adapter, so that
everything built on top of them is testable with no network and no keys. No prompts, no pipeline,
no persistence.

> The API shapes below were fetched against the live vendor documentation rather than recalled.
> Where a claim is a judgement call rather than a verified fact, it says so.

## Why ports before pipelines

The overview's second sequencing principle is ports before pipelines: the behaviours land before
anything calls them, so that everything built on top is testable with stub adapters and no network.
Without this, every later piece of work drags a live API dependency into its test suite.

Phase 2 earned the right to say `mix test.core` passes with the Postgres container stopped. That
property is worth nothing if the first pipeline reintroduces a network dependency through the front
door. The ports are what keep it: a behaviour the core never sees, a stub every test uses by
default, and a real adapter exercised only under `mix test.live`.

**Two ports, not one.** This is the phase's one genuine surprise and it shapes everything below.

---

## 3.1 Anthropic has no embeddings endpoint

The Claude API is the Messages API plus supporting endpoints — batches, files, token counting,
models. **There is no `/v1/embeddings`.** Anthropic's own recommendation is a separate vendor.

bighead cannot work without embeddings: top-`s` retrieval for the update phase is vector similarity
over dense embeddings, and the README's whole storage argument is pgvector. So the phase delivers
**two independent ports with two providers**, not one port with two callbacks. They share no key,
no base URL, and no request shape.

| Port                | Provider this phase | Why                                                     |
| ------------------- | ------------------- | ------------------------------------------------------- |
| `Bighead.LLM`          | Anthropic           | Extraction and the update tool call, both LLM-shaped    |
| `Bighead.Embedder`     | Ollama              | Local, free, no second vendor account, no per-call cost |

Ollama for embeddings is a deliberate asymmetry, not an oversight. Embedding is high-volume and
cheap to run locally; the decision phase is low-volume and quality-sensitive. Running the embedder
locally also means `mix test.live` costs nothing on the embedding half.

---

## 3.2 Environment: `env_guard`

`env_guard` (~> 2.0) declaratively reads, validates and casts environment variables in
`runtime.exs`. Two functions:

```elixir
EnvGuard.required(name, type, constraints \\ [])   # raises on missing / uncastable / invalid
EnvGuard.optional(name, type, default, constraints \\ [])  # warns and falls back to default
```

Types: `:boolean`, `:string`, `:atom`, `:integer`, `:float`, `{:list, type}`, `{:enum, [binary]}`.
Constraints: `min`/`max` on integers, `min_length`/`max_length`/`allow_empty?` on strings,
`length`/`min_length`/`max_length` on lists.

### `.env.example`

Checked in; `.env` goes in `.gitignore` and must never be committed. Every variable the app reads
appears here with a safe placeholder, because this file is the only documentation of the contract
that cannot drift silently — `EnvGuard.required/3` raises at boot when it drifts.

```sh
# --- LLM (decision phase) ---------------------------------------------------
BIGHEAD_LLM_PROVIDER=anthropic          # anthropic | ollama | stub
ANTHROPIC_API_KEY=sk-ant-...
BIGHEAD_LLM_MODEL=claude-opus-5
BIGHEAD_LLM_MAX_TOKENS=16000

# --- Embedder (retrieval) ---------------------------------------------------
BIGHEAD_EMBEDDER_PROVIDER=ollama        # ollama | stub
OLLAMA_BASE_URL=http://localhost:11434
BIGHEAD_EMBEDDING_MODEL=nomic-embed-text
BIGHEAD_EMBEDDING_DIMENSIONS=768
```

`BIGHEAD_EMBEDDING_DIMENSIONS` is not decoration. It is the `vector(N)` column width the store will
have to declare, and a mismatch between the configured model and the migrated column is a runtime
error at insert time rather than at boot. Validating it here turns that into a boot-time failure.

### `runtime.exs`

```elixir
import Config

llm_provider = EnvGuard.optional("BIGHEAD_LLM_PROVIDER", {:enum, ~w(anthropic ollama stub)}, "stub")

config :bighead, Bighead.LLM,
  provider: llm_provider,
  model: EnvGuard.optional("BIGHEAD_LLM_MODEL", :string, "claude-opus-5"),
  max_tokens: EnvGuard.optional("BIGHEAD_LLM_MAX_TOKENS", :integer, 16_000, min: 1),
  api_key: if(llm_provider == "anthropic", do: EnvGuard.required("ANTHROPIC_API_KEY", :string))

config :bighead, Bighead.Embedder,
  provider: EnvGuard.optional("BIGHEAD_EMBEDDER_PROVIDER", {:enum, ~w(ollama stub)}, "stub"),
  base_url: EnvGuard.optional("OLLAMA_BASE_URL", :string, "http://localhost:11434"),
  model: EnvGuard.optional("BIGHEAD_EMBEDDING_MODEL", :string, "nomic-embed-text"),
  dimensions: EnvGuard.optional("BIGHEAD_EMBEDDING_DIMENSIONS", :integer, 768, min: 1)
```

Three rules this shape enforces:

- **Both providers default to `stub`.** A clean checkout with no `.env` boots, and `mix test`
  passes, with no key and no Ollama. Opting in to a real provider is an explicit act.
- **`ANTHROPIC_API_KEY` is required only when the provider is `anthropic`.** Making it
  unconditionally required would break the no-keys-needed property the stub default exists for.
- **Nothing reads `System.get_env/1` outside `runtime.exs`.** One place to look, one place to
  change, and adapters that are testable because their configuration arrives as a keyword list.

---

## 3.3 The LLM port

```elixir
defmodule Bighead.LLM do
  @type message :: %{role: :user | :assistant, content: String.t()}

  @type request :: %{
          required(:messages) => [message()],
          optional(:system) => String.t(),
          optional(:schema) => map(),
          optional(:max_tokens) => pos_integer()
        }

  @type response :: %{
          content: String.t(),
          usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()},
          model: String.t()
        }

  @type reason ::
          {:refusal, String.t() | nil}
          | {:http_error, pos_integer(), term()}
          | {:transport_error, term()}
          | {:malformed_response, term()}

  @callback complete(request(), keyword()) :: {:ok, response()} | {:error, reason()}
end
```

**`complete/2` is deliberately generic.** The temptation is to write `extract_facts/2` and
`decide_operation/3` now, but those callbacks cannot be designed before the prompts they wrap
exist, and no prompt exists yet. A port that takes messages and returns content is complete today
and stable later: prompt-specific functions layer *on top of* `complete/2` without reopening the
behaviour.

`schema` carries a JSON Schema through to the provider's structured-output mechanism. It is
optional because not every call needs one, and `nil` must mean "plain text" rather than "empty
schema".

`reason` is a closed set for the same argument `MemoryOperation`'s `reason` type makes: a caller
that must branch on failure needs to tell "the model declined" from "the network broke" from "the
key is wrong", and `term()` documents none of it.

### The stub

Lives in `test/support/`, not `lib/` — it is test infrastructure, and putting it in `lib/` ships it.
Configurable per test: a canned response, a canned error, or a function the test supplies. It
records the requests it received, so a test can assert *what was sent* without a network.

---

## 3.4 The embedder port

```elixir
defmodule Bighead.Embedder do
  @callback embed([String.t()], keyword()) :: {:ok, [[float()]]} | {:error, reason()}
  @callback dimensions(keyword()) :: pos_integer()
end
```

**Batch-first.** `embed/2` takes a list and returns a list, because the extraction phase produces
several facts at once and Ollama's endpoint accepts an array natively. A single-embedding helper is
a one-line wrapper over the batch call; the reverse is a loop that pays the round trip `n` times.

`dimensions/1` exists so the migration and the runtime agree on one number, and so a stub can
declare a width without inventing vectors of the wrong size.

---

## 3.5 The Anthropic adapter

Plain `Req` — already a direct dependency. `req_llm` was considered and rejected: the behaviour
above *is* the abstraction, and layering a second one over two call shapes adds surface without
removing any.

`POST https://api.anthropic.com/v1/messages`, three headers:

| Header              | Value              |
| ------------------- | ------------------ |
| `content-type`      | `application/json` |
| `x-api-key`         | the key            |
| `anthropic-version` | `2023-06-01`       |

```elixir
Req.post(url,
  headers: [{"x-api-key", key}, {"anthropic-version", "2023-06-01"}],
  json: %{model: model, max_tokens: max_tokens, system: system, messages: messages},
  receive_timeout: :timer.minutes(2)
)
```

Five API facts this adapter must respect, each verified against current documentation:

- **`stop_reason: "refusal"` returns HTTP 200** with `content` empty or partial. Code that reads
  `content[0].text` unconditionally crashes on it. Check `stop_reason` *before* reading content and
  map it to `{:error, {:refusal, category}}` — that is what the `reason` type's first arm is for.
- **`temperature`, `top_p` and `top_k` return 400 on Claude Opus 5.** Do not add knobs the API
  rejects. Behaviour is steered by prompting.
- **Thinking is on by default on Opus 5**, and `max_tokens` caps thinking *plus* response text
  together. 16 000 is a default with room, not a tuned number.
- **Structured output is `output_config: %{format: %{type: "json_schema", schema: schema}}`** — not
  the deprecated top-level `output_format`. This is where `request.schema` lands.
- **`receive_timeout` must be raised.** Req's default is far below what a thinking model on a long
  prompt takes; the failure mode is a transport error that looks like a network fault.

Model `claude-opus-5`, $5 / $25 per million tokens in / out, 1M context, 128K max output. Haiku 4.5
at $1 / $5 is plausible for the high-volume extraction call, but that is a measurement against
real prompts rather than a decision to make here — which is exactly why `model` is configuration.

---

## 3.6 The Ollama adapter

`POST {base_url}/api/embed`:

```elixir
%{model: model, input: texts}          # input takes a string or an array
# => %{"embeddings" => [[0.1, ...], [0.2, ...]], "model" => ..., "prompt_eval_count" => ...}
```

**Use `/api/embed`, not `/api/embeddings`.** The latter is deprecated, takes `prompt` instead of
`input`, handles one string at a time, and returns `embedding` (singular). Two endpoints one
character apart with different field names in both directions is a trap worth naming here.

No authentication header — Ollama is local. `truncate` defaults to `true`, which silently shortens
an over-long input rather than failing; whether that is acceptable is an open question below.

The default model is `nomic-embed-text` at 768 dimensions. `mxbai-embed-large` (1024) and
`all-minilm` (384) are the other common choices; the dimension must match
`BIGHEAD_EMBEDDING_DIMENSIONS`, and the migrated column width once there is one.

---

## 3.7 Tests

The phase's own exit criterion is that it adds **no** network dependency to the default suite.

- **Stub-backed unit tests** for both ports: the happy path, every arm of `reason`, and the
  request-recording assertions. `async: true`, no tags.
- **Adapter tests against a stubbed transport.** `Req` supports a test adapter (`plug:` or
  `Req.Test`), so the Anthropic and Ollama adapters are testable end to end — including refusal
  handling, HTTP errors and malformed bodies — with no socket. This is where the five API facts in
  3.5 get regression tests, and it is the highest-value testing in the phase: those are exactly the
  behaviours that are expensive to discover in production.
- **`@tag :live` tests** that call the real Anthropic API and a real local Ollama. Excluded by
  default in `test_helper.exs`; run with the existing `mix test.live` alias. One per adapter,
  asserting only that a well-formed call round-trips — they are a contract check against the
  vendor, not a behaviour suite.

`mix test.core` must still pass with the Postgres container stopped, no `.env`, and no keys.

---

## Exit criteria

- [ ] `mix test.core` passes with no `.env` file, no API key, and no Ollama running
- [ ] A missing `ANTHROPIC_API_KEY` fails at boot with a named error when the provider is
      `anthropic`, and does not fail at all when it is `stub`
- [ ] `.env.example` lists every variable the app reads, and `.env` is gitignored
- [ ] No `System.get_env/1` outside `config/runtime.exs`
- [ ] `mix test.live` makes one real Anthropic call and one real Ollama call, and both round-trip
- [ ] The layering test still passes — nothing under `Bighead.Core.*` reaches `Req`, and the adapters
      are the only modules that do
- [ ] `mix precommit` green

## Explicitly out of scope

No prompts — not the extraction prompt, not the update tool schema, not the system prompts. No
retrieval, no persistence, no Ecto schemas, no pipeline, no `Bighead` public API. No streaming, no
prompt caching, no batching, no cost accounting. The ports make a call and return a value; deciding
*what to send* comes later.

## Open questions this phase deliberately leaves open

| Question                                                       | Why not here                                                        | Shape it lands on         |
| -------------------------------------------------------------- | ------------------------------------------------------------------- | ------------------------- |
| Which model for extraction vs. the update call                 | It is a measurement against real prompts, which do not exist yet    | `model` in config         |
| Retry and backoff policy on 429 / 5xx                          | The right policy depends on where the call sits in a pipeline       | the adapter's `opts`      |
| Whether over-long embedder input should truncate or fail       | Ollama defaults to truncating; the cost only shows up with real text | `truncate` in `opts`      |
| Embedding model and its dimension                              | Changing it later is a migration; changing it now is an env var      | `BIGHEAD_EMBEDDING_*`        |
| Prompt caching on the stable prefix of the extraction prompt   | There is no prefix until there is a prompt                          | the Anthropic adapter     |
