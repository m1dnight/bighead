# Phase 5 — Fact extraction (minimal)

**Goal:** one function. Hand it a `[Bighead.Core.Message]` and get `[Bighead.Core.Fact]` back, via a
single LLM call. **Nothing calls it yet.** The controller is untouched, nothing is stored, nothing
is embedded, nothing is compared against what memory already holds.

The phase delivers the extractor and its tests, and stops. Wiring it into the `Stop` hook is a
separate, later, three-line change; keeping it out means the prompt can be iterated against fixture
transcripts without a live session in the loop, and it means this phase cannot break ingest.

Its purpose is empirical: Phase 6 (`MemoryOperation` — add/update/delete) needs to be designed
against facts a real model actually returns, not against facts we imagine it returns.

## The whole pipeline

```
[Message.t()]  ──render──▶  transcript text  ──Bighead.LLM──▶  JSON  ──decode──▶  [Fact.t()] in an Extraction.t()
     (pure)                                    (boundary)                          (pure)
```

Two modules. One pure, one boundary. That split is not ceremony: the render and the decode are the
two things that change on every prompt iteration, and both are testable with no network.

---

## 5.1 `Bighead.Core.Extraction` — the pure half

The struct already exists (`scope`, `prompt_at`, `facts`, `source_message_ids`). It gains three
pure functions and the prompt text itself.

```elixir
@spec system_prompt() :: String.t()
@spec render([Message.t()]) :: String.t()
@spec request([Message.t()]) :: Bighead.LLM.request()
@spec decode(String.t(), Scope.t(), DateTime.t(), [Message.id()]) ::
        {:ok, t()} | {:error, :malformed_facts}
```

- **`system_prompt/0`** — a module attribute. It lives in the core because it is pure data and the
  thing most worth diffing between iterations. Substance, adapted from upstream bighead's
  `FACT_RETRIEVAL_PROMPT` (`bighead/bighead/configs/prompts.py`) but pointed at a *coding agent's*
  conversation rather than a consumer chat: durable preferences, tooling and workflow choices,
  project constraints, stated goals, corrections the user made. Explicitly **not**: what the
  assistant did this turn, transient state, file contents, anything only true of this one task.
  An empty list is a correct and expected answer — most turns hold no fact.
- **`render/1`** — messages in `seq` order as `role: content`, and nothing else. No JSON, no
  wrappers. **Capped**: last `@max_messages` (start at 20), each message truncated at `@max_chars`
  (start at 2_000). Phase 4 measured 0.45 MB worst case per batch, so the cap is what stops one
  tool-heavy turn becoming a 300k-token call. A constant here, not config — it moves when the
  prompt moves.
- **`request/1`** — assembles the whole completion request: the system prompt, one user message
  holding `render(messages)`, and the `{"facts": [string]}` schema
  (`additionalProperties: false`, `facts` required). It lives here rather than in the boundary so
  that the prompt, the transcript and the reply shape are one artifact — and so the `:live` test
  sends the *same bytes* as `Bighead.Extract` without restating them.
- **`decode/4`** — `Jason.decode/1`, then require `%{"facts" => list_of_binaries}`. Trim, drop
  blanks, drop duplicates within the batch, map each to `Fact.new/1` with the given `scope`,
  `extracted_at` and `source_message_ids`. Anything else is `{:error, :malformed_facts}` — never a
  raise. `event_time` stays `nil`: the model is not asked for it yet.

No clock. `prompt_at`/`extracted_at` arrive as arguments, which is what keeps the layering test
green and the decode assertable without freezing time.

## 5.2 `Bighead.Extract` — the boundary half

`lib/bighead/extract.ex`, sibling to `Bighead.Ingest` and named the same way. This is the interface the
phase delivers.

```elixir
@spec facts([Message.t()], keyword()) :: {:ok, Extraction.t()} | {:error, term()}
def facts(messages, opts \\ [])
```

It is the only impure part: reads `DateTime.utc_now/0` and calls `Bighead.LLM.complete/2`. In order:

1. `[]` → `{:error, :no_messages}`, no call.
2. Scope comes from `hd(messages).scope`. Every `Message` already carries it, so the caller does not
   have to thread one through, and `Ingest.receive/2` does not return the one it built.
3. The request comes from `Extraction.request/1`, unmodified. `Bighead.LLM.Anthropic` already carries
   `:schema` through to `output_config` (Phase 3), so the reply shape is stated to the provider
   rather than begged for in prose.
4. `decode/4` the reply. `source_message_ids` is every id in the batch, not a per-fact attribution:
   the model is not asked which message a fact came from, and inventing that mapping here would be
   a lie in the data.
5. `opts` passes through to `Bighead.LLM.complete/2` untouched, so a caller can override the model or
   raise `max_tokens` for one call.
6. `{:error, reason}` from the port passes through unchanged.

---

## Tests

- **Core, `async: true`, no db, no network:** `render/1` ordering, role prefixes, the message cap
  and the per-message truncation; `decode/4` on a valid payload, on `{"facts": []}`, on blanks and
  duplicates, on non-JSON, on `{"facts": "nope"}`, on a list holding a non-binary. The last four all
  land on `{:error, :malformed_facts}` and none of them raise.
- **Boundary, against `Bighead.LLM.Stub`:** the request carries the system prompt and the schema
  (assert via `Stub.calls/0`); a canned reply becomes an `Extraction` with the right scope and
  `extracted_at`; `{:error, {:refusal, _}}` passes through; `[]` makes **zero** calls
  (`Stub.calls() == []`).
- **One `@tag :live` test** — `mix test.live` — running the real prompt against one committed
  fixture transcript, asserting only that it returns `{:ok, %Extraction{}}`. It exists because
  prompt quality is exactly what a stub cannot tell you; run it by hand and *read the facts*.

## Exit criteria

- [ ] `Bighead.Extract.facts/1`, given messages parsed from a real fixture transcript, returns facts
      that are worth reading — checked by hand via the `:live` test
- [ ] `decode/4` never raises, on any of the malformed inputs above
- [ ] No fact text or transcript appears in any log at default configuration
- [ ] `mix test.core` passes with the Postgres container stopped
- [ ] The layering test still passes — `Bighead.Core.Extraction` reaches no clock, no `Req`, no `Repo`
- [ ] `mix precommit` green

## Explicitly out of scope

**No wiring.** `BigheadWeb.HooksController` is untouched — its `IO.inspect` stays until the phase that
uses the extractor removes it. No persistence and no Ecto schema for facts. No embedding. No dedup
against existing memories, no `MemoryOperation`, no `Decision` — Phase 6. No recall. No telemetry
event: there is no call site to measure yet, and `[:bighead, :extract, :completed]` lands with the
wiring. No `Bighead.Core.Prompt` (summary + recent + pair) — the minimal version sends the whole batch,
and that struct stays unused until the prompt is worth shaping. No `Bighead.Core.Summary`. No retries,
no rate limiting, no cost cap beyond the render cap. No `lib/bighead.ex` boundary yet.

## Open questions this phase deliberately leaves open

| Question | Why not here | Shape it lands on |
| --- | --- | --- |
| Whether the overlapping tail re-extracts the same facts every turn | Needs a store to dedup against; only bites once the extractor is wired to `Stop` | dedup at the `MemoryOperation` layer, or a high-water `seq` per run |
| Per-fact source attribution | The model is not asked for it, and guessing it poisons the audit trail | a fact carrying the `uuid` it came from, once the prompt numbers the messages |
| `event_time` on a fact | Nothing consumes an interval yet | a second field in the response schema |
| Whether assistant turns should feed extraction at all | Only measurable once real facts can be read | a role filter in `render/1` |
| Whether extraction runs on the request or off it | Undecidable before there is a call site | `Task.Supervisor` or an Oban job |
