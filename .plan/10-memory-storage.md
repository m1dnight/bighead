# Phase 10 — Memory storage

**Goal:** a `memories` table, and a store whose verbs are the storage halves of Algorithm 1's
three effectful arms — `add` for ADD, `update` for UPDATE, `supersede` for the paper's DELETE —
plus the top-`s` similarity read the update phase will retrieve candidates through (notes §2.2).
**Nothing chooses between the verbs.** No `MemoryOperation` is executed, no `Decision` is stored,
no LLM is called, and no trigger fires: the cascade that picks an arm is the update phase, and it
is better designed against a store that already exists than at the same time as building one —
the Phase 6 argument, verbatim.

The similarity read belongs in a *storage* phase, not despite the name but because of it: a
memories table you can only read back in insertion order has no exit criterion beyond a round
trip. Retrieval by vector is the only read that matters to this table's one consumer, and it is
also where `Bighead.Core.ScopeQuery` and `Bighead.Core.Scored` — both built in Phase 2 and both idle
since — finally earn their keep.

Two standing decisions do most of the shaping here. **Append-mostly** (00-overview): the paper's
DELETE removes the row and with it the audit trail and the ordering signal, so here it becomes
supersession — `superseded_at` set, row kept, every read filtered to active. And **no embedding
field in the core**: `Bighead.Core.Memory` stays vectorless (the layering test enforces it), so
vectors cross this store's API as plain arguments and live only in the row. The store does not
call `Bighead.Embedder` either — who embeds, and when, is the update phase's composition question;
a store that takes vectors as arguments is testable with hand-built ones and no stub at all.

The vocabulary follows the semantics. The store keeps the paper's names wherever its row-level
effect *is* the paper's operation — `add` inserts a fresh row, `update` keeps the id and replaces
the content — and renames the one arm whose effect diverges: a function called `delete` that runs
`UPDATE … SET superseded_at` and leaves the row readable would misdescribe its own effect to
every future reader. The decision vocabulary stays the paper's in full, in
`Bighead.Core.MemoryOperation`; the update phase is the visible translation between the two —
`{:delete, id}` becomes `supersede(id, at)` — and keeping that mapping explicit is what keeps
the store performing rather than deciding.

## The shape

```
                       ┌──▶ add(fact, vec, at)        ──▶ {:ok, Memory.t()}   (ADD: mint id, insert)
update phase (later) ──┼──▶ update(memory, vec)       ──▶ :ok                 (UPDATE: same id, new content)
                       ├──▶ supersede(id, at, by: id) ──▶ :ok                 (DELETE: mark, never remove)
                       └──▶ search(query, vec, s)     ──▶ [Scored.t(Memory.t())]  (top-s active, ranked)
```

---

## 10.1 The table

Generated with `mix ecto.gen.migration create_memories`, never hand-written.

```elixir
create table(:memories, primary_key: false) do
  add :id, :uuid, primary_key: true
  add :user_id, :text, null: false
  add :app_id, :text
  add :run_id, :text
  add :content, :text, null: false
  add :embedding, :vector, size: 768, null: false
  add :extracted_at, :utc_datetime_usec, null: false
  add :event_time, :utc_datetime_usec
  add :source_message_ids, {:array, :text}, null: false, default: []
  add :superseded_at, :utc_datetime_usec
  add :superseded_by_id, references(:memories, type: :uuid, column: :id)
  add :created_at, :utc_datetime_usec, null: false
  add :updated_at, :utc_datetime_usec, null: false
end

create index(:memories, [:user_id, :app_id, :run_id], where: "superseded_at IS NULL")
```

Each choice that is not obvious:

- **`id` is `:uuid`, and this phase answers the question `Bighead.Core.Memory.id/0` parked.** The
  typedoc left UUID-versus-bigserial "a question for whoever first needs a fact to survive a
  restart" — that is now. UUID, because the id leaks outward by design (`Decision.considered_ids`,
  telemetry metadata) and an integer there reads as a count and tempts ordering games; time-order
  already lives in `created_at`, honestly. Plain v4 via `Ecto.UUID.generate/0` — UUIDv7 buys
  ordering the row carries anyway, at the cost of a dependency. And `:uuid` rather than the
  messages table's `:text`, because that argument does not transfer: message ids arrive from a
  transcript format with no obligation to be uuids, memory ids are minted here and nowhere else,
  forever. `Ecto.UUID` loads as `String.t()`, which is exactly `Memory.id()`.
- **`embedding` is `null: false` — the opposite of the messages column, for the opposite reason.**
  There, NULL honestly means "not computed" and nothing reads the column. Here the vector is how
  a memory is found by the only read that matters; a memory without one is unfindable, which is a
  bug, and `NOT NULL` turns that bug into a constraint violation at write time instead of a
  silent retrieval gap. Same 768, hardcoded with the same comment naming
  `config :bighead, :embedder, :dimensions` as its source — a migration that changes shape with
  runtime configuration is not a migration.
- **`superseded_at` + `superseded_by_id`, no deleted anything.** Active means
  `superseded_at IS NULL`; every read this store exposes filters on it. `superseded_by_id` is
  nullable and self-referencing: the overview's "a superseded memory knows it came before the one
  replacing it" needs somewhere to point, but `{:delete, id}` carries no replacement fact, so
  whether the link gets set is the caller's affair (open questions). The FK costs nothing on a
  single-row write and keeps garbage ids out.
- **`created_at`/`updated_at` are the domain's own columns, not `timestamps/1`.** Messages
  separate `said_at` from `inserted_at` because saying and storing are different events on
  different clocks. A memory is *born in the store* — its domain `created_at` and a bookkeeping
  `inserted_at` would record the same instant twice. The struct's four timestamps map to four
  columns, all written from the struct, none Ecto-managed.
- **`source_message_ids` is a text array, not a join table.** Provenance is read whole or not at
  all; nothing queries "which memories cite message m", and a join table is a migration away if
  something ever does.
- **The scope index is partial on active.** It covers the filter half of every read this store
  has, and dead rows — which only accumulate — never bloat it. No HNSW or IVFFlat: exact KNN via
  `ORDER BY embedding <=> $1` is *correct*, the scan is bounded by one user's active memories,
  and an ANN index is an optimization with a measurable trigger (open questions).

## 10.2 `Bighead.Memories.Row` — the table, not a second domain type

Same discipline as Phase 6: one Ecto schema, and `Bighead.Memories` is the only module allowed to
know it exists. Public functions take and return `Bighead.Core.Memory`.

```elixir
@primary_key {:id, Ecto.UUID, autogenerate: false}
schema "memories" do
  field :user_id, :string
  field :app_id, :string
  field :run_id, :string
  field :content, :string
  field :embedding, Pgvector.Ecto.Vector
  field :extracted_at, :utc_datetime_usec
  field :event_time, :utc_datetime_usec
  field :source_message_ids, {:array, :string}
  field :superseded_at, :utc_datetime_usec
  field :superseded_by_id, Ecto.UUID
  field :created_at, :utc_datetime_usec
  field :updated_at, :utc_datetime_usec
end
```

- **`from_memory(memory, embedding)`** — the struct plus the vector it does not hold. The vector
  rides beside the struct through the whole API for the same reason at every call site: the core
  may not hold it, the row must.
- **`to_memory/1`** drops `embedding` and the supersession columns on the floor — active reads
  never see a superseded row, so a `superseded_at` field on the core struct would be a field that
  is provably always `nil`. Rebuilds `%Scope{}` with `Scope.new/1`, idempotent over its own
  output, as in Phase 6.

## 10.3 `Bighead.Memories` — the store

```elixir
@spec add(Fact.t(), [float()], DateTime.t()) :: {:ok, Memory.t()} | {:error, Exception.t()}
@spec update(Memory.t(), [float()]) :: :ok | {:error, :not_found | Exception.t()}
@spec supersede(Memory.id(), DateTime.t(), keyword()) :: :ok | {:error, :not_found | Exception.t()}
@spec search(ScopeQuery.t(), [float()], pos_integer()) :: [Scored.t(Memory.t())]
@spec active(ScopeQuery.t()) :: [Memory.t()]
```

- **`add/3` is the ADD arm's storage half, and where the id is minted.** `Ecto.UUID.generate/0`,
  then `Memory.from_fact/3` — the core constructor already says what a born memory looks like
  (`created_at == updated_at == at`), and the store's job is to persist that sentence, not
  restate it. Returns the built `Memory`, because the caller needs the id it did not choose.
  `at` is an argument rather than a clock read inside: the update phase will stamp one instant
  across a whole reconciliation pulse — every `Decision.decided_at`, every add, every supersede —
  and a store that reads its own clock would scatter that instant.
- **`update/2` is the UPDATE arm's storage half, and deliberately dumb.** The caller has already
  applied `Memory.apply_update/3`; the core transforms, the store persists. Writes `content`,
  `extracted_at`, `event_time`, `source_message_ids`, `updated_at` and the vector over the row —
  `created_at` untouched, id surviving, exactly Algorithm 1's UPDATE. The fresh vector is not
  optional: the content changed, and an updated memory still findable by its old vector is the
  paper's UPDATE with the retrieval half forgotten.
- **`supersede/3` is the DELETE arm, and removes nothing.** Sets `superseded_at` (and
  `superseded_by_id` when the caller passes `by:`), leaves the row. Both write-back verbs guard
  on `superseded_at IS NULL` in the `WHERE`: updating or superseding a dead memory means the
  caller is acting on a stale candidate list, and zero rows updated comes back as
  `{:error, :not_found}` — one error for one meaning, "no *active* memory by that id", covering
  absent and already-dead alike because the caller's next move is the same for both.
- **`search/3` is the top-`s` read of notes §2.2.** Active rows in the query's cover, ordered by
  `cosine_distance(row.embedding, ^vector)` (via `import Pgvector.Ecto.Query`), limited to `s`,
  selected as `{1 - distance, row}` so the score is cosine *similarity* — high is close, which is
  the orientation `Scored.rank/1` and `Scored.above/2` already assume. Ranked by construction;
  thresholding stays the caller's move via `Scored.above/2`, and `s` is an argument because the
  paper's `s = 10` is update-phase policy, not a property of the store.
- **`active/1`** — the query's cover, ordered by `created_at`: the read-back that makes every
  write checkable, and the IEx window into what a run has learned. Kept deliberately dumb;
  anything smarter is recall.
- **Reads take `ScopeQuery`, writes carry `Scope` — and their `nil`s mean opposite things.** In a
  write address, a `nil` `app_id` is "belongs to no app" and matched as `IS NULL` (the Phase 6
  `narrow/3`). In a read filter, `ScopeQuery`'s own doc says `nil` *broadens*: no clause at all,
  any value matches. The store implements both semantics side by side, one helper each, because
  collapsing them is how a per-user search silently becomes a per-run search. What `ScopeQuery`
  the update phase actually retrieves with — and whether an app-scoped read should also see
  user-level memories, the covering-ladder read — is not answered here.
- **`log: false` on `add` and `update` specifically** — their parameters are memory content,
  the same Ecto-logs-parameters path Phase 6 closed for transcripts. `supersede`'s parameters
  are ids and timestamps; `search`'s are scope ids and a vector, and Ecto does not log result
  rows. Same rescue posture as every store: `Postgrex.Error` and `DBConnection.ConnectionError`
  become `{:error, exception}`, nothing raises across the API.

## 10.4 What in-place `update` costs, said out loud

`apply_update/3` keeps the id and replaces the content, so `update/2` writes over the row and the
prior content is gone. That is Algorithm 1's UPDATE exactly, and it is *less* than the overview's
append-mostly ambition — the audit argument that upgraded DELETE applies to UPDATE too, and this
phase does not honor it there. Deliberate: an audit trail needs a consumer, none exists, and the
supersession columns already prove out the pattern an `update`-as-supersede-and-insert would
generalize (open questions). What is *not* deferred is the invariant that makes deferral safe:
nothing hard-deletes, so the day revisions matter, no data written under this phase's rules has
been destroyed by an UPDATE — only replaced, with the replacement's provenance accumulated by
`apply_update/3`'s id-union.

---

## Tests

`Bighead.MemoriesTest` through `Bighead.DataCase`, `async: true`. No LLM stub, no embedder stub —
vectors are arguments, so the tests hand-build them: a `unit_vector(i)` fixture helper
(768-wide, 1.0 at position `i`) makes cosine scores *exact* — orthogonal vectors score 0.0,
identical ones 1.0 — so search assertions are equalities, not tolerances.

- `add/3` then `active/1`: the same `Memory` back, field for field — microseconds intact, `nil`
  `event_time` still `nil`, `source_message_ids` order preserved, id a `String.t()` that
  `active/1` and `search/3` agree on
- `update/2`: content, `updated_at`, and the vector change; `created_at` does not; `search/3`
  finds the memory by its new vector and no longer by its old one
- `update/2` and `supersede/3` against a missing id and against an already-superseded id: all
  four are `{:error, :not_found}`, and the second supersede changes nothing
- `supersede/3`: the memory vanishes from `active/1` and `search/3`; the row still exists with
  `superseded_at` set (asserted through `Repo`/`Row` directly — the test module is allowed to
  know what the API rightly hides); `by:` lands in `superseded_by_id`
- `search/3`: three memories at orthogonal vectors, queried with one of them — scores exactly
  `[1.0, 0.0, 0.0]` in rank order; `s` truncates; a superseded row never appears; another user's
  memories never appear regardless of query breadth
- `ScopeQuery` semantics: memories written under two `app_id`s plus one with `app_id: nil` —
  a query naming an app returns only that app's, a query with `app_id: nil` returns all three
- `add/3` with the wrong vector width is an `{:error, _}`, not a raise — the `NOT NULL` and
  dimension constraints surface through the rescue, proving the store's error posture

## Exit criteria

- [ ] `add/3` → `active/1`/`search/3` round-trips `Bighead.Core.Memory` structs identical to what
      `Memory.from_fact/3` built, microseconds included
- [ ] `search/3` over hand-built vectors returns exactly the expected candidates, scores, and
      order — asserted as equalities
- [ ] `supersede/3` removes a memory from every read this store exposes and deletes nothing —
      the row is still in the table
- [ ] Nothing outside `Bighead.Memories` references `Bighead.Memories.Row`; nothing in `lib/bighead/core/`
      gained an embedding, a `Repo`, or a clock — layering test green
- [ ] No memory content in any log at default dev configuration, Ecto's parameter logging
      included
- [ ] `mix test.core` green with the Postgres container stopped
- [ ] `mix precommit` green

## Explicitly out of scope

**No caller.** Nothing executes a `MemoryOperation`, nothing persists a `Decision`, and the
choice between the three verbs — the retrieve → present → parse cascade — is the update phase,
designed against this store. **No embedder call**: vectors arrive as arguments; whether the
update phase embeds a fact once and reuses the vector for both `search` and `add` is its
composition to make. **No update prompt, no LLM call, no trigger** — the `Stop` route keeps
doing exactly what Phase 8 left it doing. **No recall**: `user_prompt_submit` still answers
`""`, and the covering-ladder read stays unbuilt. **No revision audit for UPDATE** (§10.4). **No
ANN index.** **No retention, forget API, or export.** **No `s`, no threshold** — both are the
update phase's constants; this store takes limits as arguments and returns scores unjudged.

## Open questions this phase deliberately leaves open

| Question | Why not here | Shape it lands on |
| --- | --- | --- |
| UPDATE audit — prior content lost on `update` | The audit needs a consumer; supersession already proves the pattern | `update` becoming supersede-and-insert, or a revisions table |
| Whether DELETE's superseder is the contradicting fact's memory | `{:delete, id}` carries no fact; only the cascade knows what contradicted | the update phase passing `by:` after its own `add` |
| The `ScopeQuery` the update phase retrieves with | Per-user, per-app, per-run reconciliation is dedup *policy* | a constant beside `s`, in the update phase |
| Covering-ladder reads — user-level memories visible inside an app | Recall's question; wants `Scope.covering/1`, which does not exist | exact-or-null per rung, in `for_query/1` |
| When an ANN index earns its keep | Needs live row counts per user, which need a writer | an HNSW migration, triggered by a measured scan cost |
| Whether `search` should exclude the memory's own source run | Only meaningful once reconciliation runs per-turn | a `ScopeQuery` refinement, or a `WHERE` in the update phase |
