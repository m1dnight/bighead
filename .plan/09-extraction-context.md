# Phase 9 — Extraction context (φ(P))

**Goal:** extraction stops reading a bare message window and starts reading the paper's
`P = (S, recent, new)` — the run's *potential* summary, the recent stored messages as
disambiguation context, and the new exchange as the only extraction target (notes §2.1). One pure
builder assembles `P` from a run's history, one boundary composition fetches that history from the
stores, and `φ(P)` consumes it. **Nothing triggers it.** The controller is untouched, `stop.py` is
untouched, no fact is extracted as a side effect of any hook, and no fact is stored — extraction
gains its context, not its caller.

"Potential" is doing work in that sentence: `Summaries.latest/1` answers `nil` for every run
younger than `max_lag`, and that is a legitimate state, not a degenerate one. A prompt with no `S`
and less than a window of history must degrade to exactly what Phase 5 sends today — the window,
nothing else — with no special case anywhere. `S` sharpens extraction when it exists; its absence
never blocks it.

The ordering — context before trigger, trigger before the update phase — repeats Phase 5's
empirical argument one level up. The update phase (`Decision`, `MemoryOperation`, the memories
table) wants designing against the facts `φ(P)` actually returns, and `φ(P)`'s facts differ from
`φ(window)`'s in exactly the way `S` exists to cause: pronouns resolved, referents named, the
fact stated so it survives with no conversation around it. Wiring a trigger first would spend
tokens per turn producing facts that nothing stores and no one reads; wiring the context first
means the prompt can be iterated from IEx against a real run's real summary, which is the same
no-live-session-in-the-loop property every phase since 5 has bought on purpose.

The critical nuance this phase imports from the paper, stated once here and enforced in the
prompt: facts are extracted **from the new exchange only**, while *remaining aware* of the broader
context. `S` and `recent` resolve "it", "there" and "that approach"; they are not extraction
targets. Without that constraint every turn re-extracts the entire history — and re-extracts `S`
itself, which is memory laundered back into facts.

## The whole pipeline

```
            Summaries.latest/1 ──▶ S | nil ──┐
Scope ──┤                                    ├──▶ Prompt.from_history ──▶ P = (S, recent, new)
            Messages.for_run/1 ──▶ history ──┘        (pure split at `since`)
                                                             │
P ──render──▶ sectioned prompt text ──Mem0.LLM──▶ {"facts": [...]} ──decode──▶ [Fact.t()] in Extraction.t()
    (pure)                           (boundary)                        (pure; provenance = new ids only)
```

Same two seams as Phase 5, one struct richer. `Mem0.Core.Prompt` and `Mem0.Core.Extraction` stay
pure — no clock, no store, same layering test. `Mem0.Extract` grows the store reads the way
`Mem0.Summarize.refresh/2` did in Phase 8, and for the same reason: the composition goes in the
module that already owns the impure step, because a new module would be surface for one function.

---

## 9.1 `Mem0.Core.Prompt` — reshaped, because the pair was the wrong unit

The struct exists (Phase 2) and nothing but test fixtures constructs one, so it is reshaped
rather than versioned:

```elixir
typedstruct enforce: true do
  field :scope, Scope.t()
  field :summary, Summary.t(), enforce: false
  field :recent, [Message.t()]
  field :new, [Message.t()]
end
```

- **`pair :: {Message.t(), Message.t()}` dies.** The paper's `(m_{t-1}, m_t)` assumes strict
  alternation; a Claude Code turn stores one user message and a variable number of assistant
  messages, and the normalizer decides how many survive. Forcing two would either drop
  intermediate assistant messages — a fact in a dropped message is a fact never extracted, the
  Phase 7 render argument verbatim — or fake an alternation the transcript does not have. The
  paper's own gloss is "one complete interaction unit"; `new` is that unit with its real shape.
  What is preserved is the invariant, not the arity: extract from `new` only.
- **`:at` leaves the struct.** A prompt is an input to a call, not an event; the boundary stamps
  time when it fires, exactly as `Extract.facts/2` does today, and a clock-adjacent field the
  core never reads is surface for drift.
- **`from_history/1` is the builder**, and the only place the split lives:

  ```elixir
  @spec from_history(keyword()) :: {:ok, t()} | {:error, :nothing_new}
  # :messages — the run's stored history, any order
  # :since    — watermark seq; messages past it are the new exchange. nil: everything is new.
  # :summary  — Summary.t() | nil, defaults to nil
  ```

  Sorts by `seq` — pure function, output independent of the order a caller held the list in —
  splits at `since` (`seq > since` is new, the rest is recent), takes the scope from the first
  message, and answers `{:error, :nothing_new}` when the new slice is empty, whether because the
  run is empty or because `since` is at or past the head. One error for one meaning: no call
  should be made. `since: nil` means no watermark, everything pending — deliberately the same
  contract `Messages.count_since/2` just adopted, because it is the same question asked of a list
  instead of a table.
- **`since` is its own parameter, not the summary's `through_seq`.** The two watermarks measure
  different things and legitimately disagree: `S` may lag up to `max_lag` behind the head by
  design, while `since` marks where the last *extraction* stopped. The messages between
  `through_seq` and `since` are exactly the recent context that covers the summary's gap —
  collapsing the two would either re-extract that gap every turn or silently hide it from the
  model. What `since` is in production is the trigger phase's question; here every caller states
  it.
- `new/1` stays as the dumb constructor the fixture and constructors tests use; `from_history/1`
  is what everything else calls. The core trusts its input: no cross-checking that the summary's
  scope matches the messages' — one validation point, at the boundary, per the standing decision.

## 9.2 `Mem0.Core.Extraction` — the prompt learns to tell context from target

`request/1` and `render/1` are rewritten to take a `Prompt.t()`, not wrapped — the Phase 8
`stale?/2` argument: the add-a-new-function rule protects callers, and the only callers are
`Mem0.Extract` and the `:live` test, both of which this phase changes anyway. `decode/4` is
untouched.

- **`render/1`** produces sectioned user content in place of the flat transcript:

  ```
  # Conversation summary
  {S.text}

  # Earlier messages (context)
  role: content …

  # New messages (extract from these only)
  role: content …
  ```

  The summary section is omitted entirely when `S` is `nil` — a young run's prompt should *be*
  Phase 5's prompt, not Phase 5's prompt plus an empty ceremony section. `recent` keeps the
  `@max_messages` cap (20, unchanged in value) — it now denominates the context window rather
  than the whole input, which is what it was always sized for. `new` is **count-uncapped**: every
  message in the exchange is an extraction target, and the Phase 7 argument applies — nothing is
  ever silently excluded from the extractor's view of the exchange. `@max_chars` (2_000) trims
  every message in every section; the caps stay Extraction's own constants, moving when this
  prompt moves.
- **`system_prompt/0`** keeps every content rule it has — durable, cross-project, third person,
  the user over the assistant, empty list usually right — and gains the structural one: the
  summary and earlier messages are context for resolving references, never a source of facts;
  extract only from the new messages. This sentence is the phase's load-bearing line: without it
  the model re-extracts `S` every turn, and the summary becomes a fact-duplication engine instead
  of a disambiguator.
- **`request/1`** — system prompt, one user message holding `render(prompt)`, the same
  `{"facts": [string]}` schema. One place builds it, so the `:live` test and the boundary send
  the same bytes.

## 9.3 `Mem0.Extract` — the boundary, now two functions

```elixir
@spec facts(Prompt.t(), keyword()) :: {:ok, Extraction.t()} | {:error, term()}
@spec facts_since(Scope.t(), integer() | nil, keyword()) :: {:ok, Extraction.t()} | {:error, term()}
```

- **`facts/2`** takes the assembled prompt: scope from `prompt.scope`, request from
  `Extraction.request/1`, one `DateTime.utc_now/0` stamping `prompt_at` and every fact's
  `extracted_at`, `opts` through to `Mem0.LLM.complete/2` untouched, port errors through
  unchanged. A hand-built prompt with an empty `new` is refused with `{:error, :no_messages}`
  before any call — Phase 5's "a call that should never be made" posture, kept.
- **`source_message_ids` becomes the new slice's ids only.** Phase 5 passed every id in the batch
  and said why: inventing per-message attribution would be a lie in the data. The same argument
  now *narrows* the list — a fact cannot have come from a context section the prompt forbade as a
  source, so naming `recent`'s ids in provenance would be the very lie the field was shaped to
  avoid. Per-fact attribution stays out of scope; exchange-level attribution gets honest.
- **`facts_since/3` is the wiring this phase exists for**: `Summaries.latest/1`, then
  `Messages.for_run/1`, then `Prompt.from_history/1`, then `facts/2`. `{:error, :nothing_new}`
  short-circuits with zero LLM calls. It is the IEx and `:live` entry point — point it at a run
  the hook path really filled, and the extraction runs against that run's real summary. Kept
  separate from `facts/2` rather than folded in, so the LLM call stays testable against the stub
  with no database in the suite, and so a prompt can be assembled and *read* before tokens are
  spent on it.
- The whole-run read is the simplest correct read: `for_run/1` already exists, and a windowed
  query (`since` minus a window) is an optimization for a phase that can measure it.

## 9.4 The arithmetic this phase makes real

Phase 8 fixed `max_lag`'s unit so that this sentence could be true: at any `Stop` pulse, `S` lags
at most 10 stored messages behind the head, and extraction's context window holds the 20 messages
before the new exchange — so the gap between what `S` has read and what `recent` shows is covered
by construction, provided a turn stays smaller than the difference. That proviso is now a real
invariant with a real failure mode (a 15-message turn leaves messages no context covers), it is
machine-shape-dependent, and the `[:mem0, :summarize, :refresh]` telemetry Phase 8 added is the
instrument for watching it. This phase writes the invariant down and changes neither constant:
retuning either cap belongs to the phase that can read the live ratio.

---

## Tests

- **Core, `async: true`, no db, no network:** `from_history/1` splits gapped seqs correctly
  (messages at 3, 17, 40: `since: 3` puts two in `new`; `since: 40` and an empty list are both
  `:nothing_new`; `since: nil` puts everything in `new`), sorts shuffled input, carries the
  optional summary. `render/1`: the summary section present exactly when `S` is; `recent` capped
  at 20; a `new` slice past 20 comes through whole; char truncation in every section; ordering
  within sections. `request/1` carries the system prompt and the schema. The `decode/4` suite is
  untouched. Constructors test and `core_fixtures` updated for the reshaped struct.
- **Boundary, against `Mem0.LLM.Stub`:** the request bytes place the summary text and both
  message sections where `render/1` says (assert via `Stub.calls/0`); the extraction's and every
  fact's `source_message_ids` name only `new`'s ids even when `recent` is present; an empty-`new`
  prompt makes zero calls; a port error passes through.
- **Composition, `Mem0.DataCase` + `Stub`** — the Phase 8 pattern: `facts_since/3` on a run with
  a stored summary sends that summary's text; on a run with none sends no summary section; with
  `since` at the head makes zero calls; on an empty run makes zero calls.
- **One `@tag :live` test**, run by hand and *read*: the same fixture conversation extracted
  twice — once with `since: nil` and no summary, once over its tail with the summary a real
  Phase 7 regeneration produced. The property to read for: the second run's facts come only from
  the tail, and references the tail cannot resolve alone arrive resolved.

## Exit criteria

- [ ] `facts_since/3` against a run filled through the live hook path returns facts worth
      reading, informed by that run's stored summary — checked by hand via the `:live` test
- [ ] A run with no summary and thin history produces Phase 5's prompt shape — no summary
      section, no special case in any caller
- [ ] Every fact's `source_message_ids` name only the new exchange
- [ ] `:nothing_new` paths make zero LLM calls — asserted via `Stub.calls/0`
- [ ] No summary, fact or transcript text in any log at default dev configuration — canary method
- [ ] `mix test.core` green with the Postgres container stopped; layering test green —
      `Prompt` and `Extraction` still reach no clock, no `Req`, no `Repo`
- [ ] `mix precommit` green

## Explicitly out of scope

**No trigger.** Nothing in production calls `facts_since/3`; the `Stop` route keeps doing exactly
what Phase 8 left it doing. The extraction watermark — what `since` is on a live turn — is the
trigger phase's question, and it is unanswerable here: a watermark needs somewhere durable to
live, and facts need somewhere to land before extracting them per-turn is anything but token
spend. **No fact persistence** — no facts table, no memories table, no embedder call, no
`Decision`/`MemoryOperation` execution: the update phase, designed against what this phase lets
us read. **No recall change**: `user_prompt_submit` still answers `""`. **No app- or user-rung
summaries in the prompt** — `S` is per-run; reading up the covering ladder is recall's question.
**No per-fact attribution and no `event_time`** — re-parked from Phase 5, unchanged. **No
extraction telemetry** — `[:mem0, :extract, :completed]` lands with the trigger, where there is a
call site worth measuring; re-parked from Phase 5. **No retuning** of `@max_messages`, `@max_chars`
or `max_lag` (§9.4).

## Open questions this phase deliberately leaves open

| Question | Why not here | Shape it lands on |
| --- | --- | --- |
| The extraction watermark — what `since` is per turn | Needs durable state and a trigger; facts land nowhere yet | a high-water `seq` per run, stored beside whatever the update phase stores |
| Where facts land, and dedup against what memory holds | The update phase, designed against `φ(P)`'s real output | `Decision` over `MemoryOperation`, the memories table, top-`s` similarity |
| When extraction fires relative to the summary refresh | Both ride the `Stop` pulse eventually; extraction wants the freshest `S`, refresh is async | sequencing both in one task per pulse, refresh before extract |
| A turn larger than `recent`'s window (§9.4) | Machine-shape-dependent; only live ratios can rank the fix | raise the cap, or a turn-aware split in `from_history/1` |
| Whether `S` at broader rungs ever feeds extraction | No app/user summaries exist to read | recall's covering-ladder read, if it ever proves out |
