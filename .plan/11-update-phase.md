# Phase 11 — The update phase

**Goal:** Algorithm 1 finally runs. A `Stop` pulse turns the run's new exchange into memories:
extract facts past a watermark, and for each fact retrieve → present → parse → perform against
`Mem0.Memories`. This is the phase every prior phase deferred to by name — the cascade that
chooses between the store's verbs — and it is almost entirely composition: `Extract.facts_since/3`
produces the facts, `MemoryOperation.parse/4` reads the verdicts, `Mem0.Memories` performs them,
and the ports and stubs make the whole chain testable without a network. The only genuinely new
pieces are the update request (the one prompt the system still lacks), a cursor so the pulse
knows where it left off, and the boundary module that strings them together.

One phase rather than a machinery/wiring split (the 7-then-8 pattern), deliberately: the
machinery here has exactly one caller, the pulse, and the pulse's design questions — watermark,
at-least-once, race posture — are what shaped the store APIs in phases 9 and 10. Planning them
apart would re-open settled questions in two documents.

Two standing decisions do the shaping. **`MemoryOperation` is the purity pivot** (00-overview):
the core decides *what*, wrapped in a `Decision`; the boundary performs it. Nothing in this phase
puts a rule in the boundary that the core could hold. And **one instant stamps a pulse**
(phase 10's `add/3` doc): every `decided_at`, every `created_at`, every `superseded_at` in one
reconciliation carries the same `DateTime`, read once at pulse start.

## The shape

```
Stop ──▶ ingest ──▶ Messages.put ──▶ Summarize.refresh_async   (exists)
                              └────▶ Reconcile.pulse_async     (new, same Task pattern)

pulse(scope):
  through_seq = ExtractionState.through_seq(scope)             # nil on first pulse
  {:ok, extraction} = Extract.facts_since(scope, through_seq)  # or nothing new → done
  for fact <- extraction.facts:
    {:ok, [vector]} = Embedder.embed([fact.content])           # once per fact
    candidates      = Memories.search(user_query, vector, 10)  # top-s, paper's s
    {:ok, decision} = LLM ▷ MemoryOperation.decode(reply, fact, memories, at)
    perform(decision.operation, vector, at)                    # the four arms
  ExtractionState.advance(scope, extraction.through_seq, at)   # only on completion
```

---

## 11.1 The extraction cursor

Extraction needs what summaries already have: a record of how far into the message history it
has read, so a pulse consumes each exchange once. Summaries derive theirs from their own rows
(`through_seq` on the artifact); extraction cannot — a pulse that extracts *zero* facts leaves
no artifact, and the watermark must advance because messages were considered, not because facts
came out. So the cursor is its own row: one per scope, updated in place.

Update-in-place is a first for this codebase and it is fine here: this is bookkeeping about the
pipeline, not domain data about the user — nothing the append-mostly rule protects (audit,
ordering, supersession history) lives in this table. What the mutable row gives up is pulse
history, which telemetry already carries live.

Generated with `mix ecto.gen.migration create_extraction_state`:

```elixir
create table(:extraction_state) do
  add :user_id, :text, null: false
  add :app_id, :text
  add :run_id, :text
  add :through_seq, :integer, null: false
  add :pulsed_at, :utc_datetime_usec, null: false
  timestamps(type: :utc_datetime_usec)
end

create unique_index(:extraction_state, [:user_id, :app_id, :run_id], nulls_distinct: false)
```

- **The scope is the identity but cannot be the primary key**: PK columns must be `NOT NULL`,
  and a nil `app_id` is a legitimate address. Hence the default bigserial id plus a unique
  index — and that index must be **`nulls_distinct: false`** (Postgres 15+; dev runs pg18).
  In a default unique index `NULL ≠ NULL`, so a bare `{user, nil, nil}` scope would grow a
  second row on every pulse, `ON CONFLICT` would never fire, and every read of that scope's
  watermark would be ambiguous. This is the quiet failure mode of scope-keyed upserts, and the
  index option is the whole defense. No sentinel values: coalescing nil to `""` in the row
  would re-introduce exactly the blank-versus-nil ambiguity `Scope.new/1` exists to remove.
- **`through_seq`** follows the `Summary.through_seq` convention: the seq of the last message
  the pulse's extraction consumed. **`pulsed_at`** is the pulse's one instant, for IEx and
  staleness eyeballing; `timestamps/1` is Ecto bookkeeping, and this table being bookkeeping
  itself, that is honest rather than redundant.
- **One writer, narrow charter.** The pulse writes it; nothing else does. No summary state, no
  memory counts — summaries already carry their own watermark, and a second copy here is a
  second source of truth to drift. A future kind of per-scope state earns its column when it
  has a writer.

### `Mem0.ExtractionState` — the store

```elixir
@spec through_seq(Scope.t()) :: non_neg_integer() | nil
@spec advance(Scope.t(), non_neg_integer(), DateTime.t()) :: :ok | {:error, Exception.t()}
```

- **`through_seq/1`** reads the exact scope — the Phase 6 `narrow/3`, `IS NULL` included — and
  returns `nil` for a scope never pulsed, which is exactly the "no watermark" value
  `Extract.facts_since/3` already accepts.
- **`advance/3` is an upsert, and monotonic.** `INSERT … ON CONFLICT` on the scope index with
  `through_seq = GREATEST(EXCLUDED.through_seq, existing.through_seq)`. Two concurrent pulses
  both read watermark W and race to write; last-write-wins would let the loser drag the
  watermark *backwards*, and `GREATEST` makes arrival order irrelevant instead of locking it
  away. `pulsed_at` is set unconditionally — it means "last pulse", not "furthest pulse".
- Same error posture as every store; a `Row` module owned by this store alone; the layering
  test's `@table_owners` and `@repo_callers` each grow one entry.

## 11.2 The update request — the core's half of the conversation

`Mem0.Core.MemoryOperation` already reads the model's answer (`parse/4`, ordinals, the
information-gain guard). This phase adds the question, in the same module — request and parse
are two halves of one protocol, and splitting them invites drift:

```elixir
@spec request(Fact.t(), [Memory.t()]) :: Mem0.LLM.request()
@spec decode(String.t(), Fact.t(), [Memory.t()], DateTime.t()) ::
        {:ok, Decision.t()} | {:error, reason()}
```

- **`request/2`** renders the candidate fact plus the retrieved memories **as ordinals `1..s`,
  contents only** — ids never reach the model (module doc, already written, now enforced by
  construction). The system prompt states Algorithm 1's cascade *in its order*: not similar →
  ADD; contradicts → DELETE; augments → UPDATE; else → NOOP. The order matters and is the
  notes' §2.3 warning — contradiction is checked before augmentation, so a fact that both
  contradicts one memory and augments another resolves as the contradiction. The response
  schema pins `{"event": ..., "id": ..., "reason": ...}` with `additionalProperties: false`,
  `event` and `reason` required, `id` required only by the prose (the schema cannot express
  "required when UPDATE/DELETE"; `parse/4` already returns `:missing_ordinal` for that).
- **`decode/4`** is `Jason.decode` + `parse/4` + the wrap into `Decision` — the same
  reply-to-core-struct step `Extraction.decode/4` and `Summary.decode/4` established, ending at
  the same place: a core value the boundary can perform. `considered_ids` is the candidates'
  ids in presentation order; `reason` is the model's, stored verbatim on the struct (it is why
  `Decision` exists); `decided_at` is the pulse instant, passed in — the core still reads no
  clock. An empty candidate list is legal and expected: the model sees no numbered memories
  and the only in-range answers are ADD and NOOP, which `parse/4` already guarantees because
  any ordinal is out of range against `[]`.

## 11.3 `Mem0.Reconcile` — the boundary that performs

```elixir
@spec pulse(Scope.t(), keyword()) :: {:ok, [Decision.t()]} | :nothing_new | {:error, term()}
@spec pulse_async(Scope.t(), keyword()) :: :ok
@spec reconcile(Extraction.t(), keyword()) :: {:ok, [Decision.t()]}
```

- **`reconcile/2` drives one extraction's facts through the cascade, sequentially.** Per fact:
  embed the content (`Mem0.Embedder.embed/2`, first real consumer of the port), retrieve
  `Memories.search(query, vector, @max_memories)`, ask, `MemoryOperation.decode/4`, perform.
  Sequential rather than concurrent on purpose: facts from one exchange are often *about the
  same thing*, and fact 2 must see the memory fact 1 just added or the cascade dedups nothing.
  The paper's incremental design says the same — newly added memories are immediately usable.
- **The retrieval policy lives here, as constants** — the store took them as arguments so this
  module could own them. `@max_memories 10` is the paper's `s`. The `ScopeQuery` is the
  **user-broad cover**: `ScopeQuery.new(user_id: fact.scope.user_id)` — reconciliation is
  dedup, and a fact stated in this run that contradicts a memory born in another app is
  exactly the contradiction the cascade exists to catch. Narrowing to the app or run would
  partition the user's memory into stores that cannot correct each other. (Whether *recall*
  should read that broadly is a different question and stays open.)
- **Performing is a translation, verb for verb**: `{:add, fact}` →
  `Memories.add(fact, vector, at)`, reusing the vector the fact was searched with — embed once,
  the composition question phase 10 left to this module, answered. `{:update, id, fact}` →
  `Memory.apply_update(memory, fact, at)` over the candidate already in hand, then
  `Memories.update(updated, vector)` — the updated content *is* the fact's content, so the
  same vector is the fresh vector; no second embedding exists to forget. `{:delete, id}` →
  `Memories.supersede(id, at)` — the visible rename, `by:` left unset because the cascade
  knows what contradicted but not which *memory* replaces the dead one; still open. `:noop` →
  nothing, by doing nothing.
- **A fact that fails does not kill the pulse.** An LLM error, a malformed verdict, a store
  error on one fact is telemetered and skipped; the remaining facts still reconcile. Memory is
  best-effort by nature and the extraction prompt already says most turns yield nothing — one
  bad verdict costing the whole exchange would invert that posture. The pulse as a whole still
  completes and advances the cursor; what was skipped is visible in telemetry, not silently
  gone forever only if re-extraction would never happen — which is the next bullet.
- **Telemetry, not logs, and no content** — the redaction policy: operation tags, counts,
  scope ids, duration. The `Decision` structs come back to the caller (tests, IEx) and are not
  persisted; a decisions table needs a consumer, the same argument that deferred the revision
  audit.

## 11.4 The pulse and the wiring

- **`pulse/2` is read-cursor → extract → reconcile → advance-cursor**, in that order, and the
  order is the crash-safety argument: the cursor advances only after reconciliation ran to
  completion. A pulse that crashes mid-cascade advances nothing, so the next `Stop` re-extracts
  the same slice — **at-least-once, with the cascade as the dedup layer**: a fact re-presented
  against the memory it already produced comes back NOOP (or UPDATE, harmlessly). The opposite
  order — advance first — turns a crash into silently lost facts that nothing ever revisits.
  Two pulses racing the same slice is the same story with the same absorber, plus `GREATEST`
  keeping the cursor monotonic. Tolerated, not prevented; serializing pulses per scope is a
  worker-phase question with a measurable trigger.
- **A pulse with nothing new touches nothing.** `Extract.facts_since/3` refuses before any LLM
  call; the cursor stays, telemetry notes a quiet pulse. **A pulse whose extraction yields zero
  facts advances the cursor** — the messages were considered, and this case is why the cursor
  is not derived from memory provenance.
- **`Extraction` gains a `through_seq` field**, stamped in `Extract.facts/2` from the max seq
  of `prompt.new` — the extraction names its own extent, as a `Summary` does, rather than the
  pulse reconstructing it from message ids.
- **`pulse_async/2`** is `pulse/2` on a supervised task — its own `Task.Supervisor` beside
  `Summarize.TaskSupervisor` in the application tree, the same `notify_pid` test seam, the
  same always-`:ok` return. The `Stop` route becomes ingest → `Messages.put` →
  `Summarize.refresh_async` → `Reconcile.pulse_async`, and still answers before any model
  work starts — Claude Code is blocked on that reply. The summary race is benign: if the
  refresh and the pulse interleave, extraction reads the previous summary, which is context,
  not provenance, and the new messages are in the prompt regardless.

---

## Tests

The core half through plain ExUnit, no stubs: `request/2` renders ordinals and contents and no
ids; `decode/4` builds a `Decision` carrying reason, considered ids in order, and the pulse
instant; an empty candidate list decodes ADD and NOOP and refuses ordinals.

`Mem0.ExtractionStateTest` through `DataCase`: a scope never pulsed reads `nil`; advance then
read round-trips; **a bare `{user, nil, nil}` scope advanced twice holds one row** — the
`nulls_distinct: false` proof, asserted through `Repo` on the row count; advance to 10 then to
5 reads 10 — monotonicity as an equality; two scopes differing only in `run_id` do not share a
cursor.

`Mem0.ReconcileTest` through `DataCase` with `LLM.Stub` and `Embedder.Stub`, scripted verdicts:

- each arm end-to-end: ADD lands a memory `Memories.active/1` can read back; UPDATE keeps the
  id, replaces the content, and the memory is findable by the new content's vector; DELETE
  supersedes — gone from active, row still present; NOOP leaves the store byte-identical
- fact 2 sees fact 1's memory: two facts in one extraction, the stub answering ADD then UPDATE
  against ordinal 1 — proves sequential reconciliation and the immediately-usable property
- one fact's LLM error skips that fact and reconciles the rest; the cursor still advances
- a pulse with nothing new returns without an LLM call and without touching the cursor; an
  extraction with zero facts advances it
- ids never reach the model: assert on `LLM.Stub.calls/0` that no candidate memory id appears
  in any request — the module-doc promise as a test rather than a sentence

`Mem0Web.HooksControllerTest` through `ConnCase`: a `Stop` payload with a fresh exchange, stub
adapters scripted to one fact and ADD, ends with a memory in the store and the cursor at the
exchange's last seq — the phase, asserted through the public route with the `notify_pid` seam.

## Exit criteria

- [ ] A `Stop` payload produces a memory row and an advanced cursor end-to-end under stub
      adapters, asserted through the controller
- [ ] All four arms of Algorithm 1 proven against the real store, including the
      information-gain degrade to `:noop`
- [ ] A pulse that fails mid-cascade leaves the cursor untouched; the next pulse re-extracts
      the same slice
- [ ] The cursor is monotonic and one-row-per-scope, nil scopes included
- [ ] No fact content, memory content, or model reasoning in any log or telemetry metadata at
      default dev configuration
- [ ] Layering tests green: new table owned by its store alone, core still clockless and
      vectorless, `Mem0.Reconcile` reaches no `Row`
- [ ] `mix test.core` green with the Postgres container stopped
- [ ] `mix precommit` green

## Explicitly out of scope

**No recall.** `user_prompt_submit` still answers `""`; nothing reads memories back into a
conversation, and the covering-ladder read stays unbuilt. **No Decision persistence** — built,
returned, telemetered, not stored; a decisions table needs a consumer. **No `by:` on
supersede.** **No similarity threshold** — the paper presents the raw top-`s` and so does this
phase; `Scored.above/2` waits for a measured reason. **No per-fact retry queue** — a skipped
fact is telemetry, and the at-least-once cursor bounds the loss to completed-pulse gaps. **No
per-scope pulse serialization** — the race is tolerated and absorbed. **No revision audit, no
ANN index, no retention** — phase 10's deferrals, still deferred. **No live-API test** beyond
the existing `test.live` pattern if one proves cheap.

## Open questions this phase deliberately leaves open

| Question | Why not here | Shape it lands on |
| --- | --- | --- |
| Decision persistence | Needs a consumer — an audit UI, a debug view, an eval | a `decisions` table FK'd to memories, written in `perform` |
| `by:` on DELETE | The verdict names the contradicted memory, not its successor | the cascade linking a same-pulse ADD to its DELETE |
| Similarity threshold on candidates | Paper presents raw top-`s`; a cutoff needs measured noise | `Scored.above/2` between search and present |
| Per-scope pulse serialization | Races are absorbed by the cascade; serializing needs a measured cost | a per-scope worker owning the pulse |
| `InformationContent` measure | Word count is a placeholder the phase inherits, not settles | a richer `richer?/2` injected at `decode/4` |
| Whether recall reads user-broad like reconciliation | Recall's question; wants `Scope.covering/1` | the recall phase's own `ScopeQuery` policy |
