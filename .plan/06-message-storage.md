# Phase 6 — Message storage

**Goal:** a `messages` table, and a store that puts `Mem0.Core.Message` structs into it and reads
them back as the same structs. **Nothing calls it.** `Mem0.Ingest` is untouched, the controller is
untouched, and no message is persisted as a side effect of anything yet.

Same shape as Phase 5: the interface and its implementation, exercisable from IEx and from tests,
with the wiring left as a separate decision. That is deliberate here — the moment ingest writes on
every `Stop`, questions about overlapping tails and duplicate turns become urgent, and those are
better answered against a table that already exists than at the same time as building one.

---

## 6.1 The table

Generated with `mix ecto.gen.migration create_messages`, never hand-written.

```elixir
create table(:messages, primary_key: false) do
  add :id, :text, primary_key: true
  add :user_id, :text, null: false
  add :app_id, :text
  add :run_id, :text
  add :role, :text, null: false
  add :content, :text, null: false
  add :said_at, :utc_datetime_usec, null: false
  add :seq, :integer, null: false
  add :embedding, :vector, size: 768
  timestamps(type: :utc_datetime_usec, updated_at: false)
end

create index(:messages, [:user_id, :app_id, :run_id, :seq])
```

Each choice that is not obvious:

- **`id` is `:text`, not `:uuid`.** Every id is a Claude Code uuid today, so `:uuid` would fit —
  but `Mem0.Core.Message.id/0` is `String.t()` by design (02-domain-data: ids stay opaque), and a
  second transcript format is under no obligation to use uuids. A text column costs an index page
  or two; a uuid column costs a migration on a populated table the first time one does not.
- **`role` is `:text`, not a Postgres enum.** Extending an enum is a migration; the closed set
  already lives in the core.
- **`said_at` is `:utc_datetime_usec`.** Claude Code stamps milliseconds and `:utc_datetime`
  truncates them silently, which would leave two messages in the same second orderable only by
  `seq`. `config/config.exs` already defaults generators to usec.
- **`inserted_at`, no `updated_at`.** What was said was said.
- **No unique index on `(user_id, app_id, run_id, seq)`.** It looks right, and it would fail a whole
  batch over a cosmetic duplicate. Left out until the overlap question is actually answered.

The index covers the only read this phase makes, and its prefix matches the shape
`Scope.covering/1` will want later.

## 6.2 `Mem0.Messages.Row` — the table, not a second domain type

One Ecto schema over that table, and `Mem0.Messages` is the only module allowed to know it exists.
Its public functions take and return `Mem0.Core.Message`, so nothing else in the system grows an
Ecto dependency.

```elixir
@primary_key {:id, :string, autogenerate: false}
schema "messages" do
  field :user_id, :string
  field :app_id, :string
  field :run_id, :string
  field :role, :string
  field :content, :string
  field :said_at, :utc_datetime_usec
  field :seq, :integer
  field :embedding, Pgvector.Ecto.Vector
  timestamps(type: :utc_datetime_usec, updated_at: false)
end
```

- **`to_row(message, inserted_at)`** returns a plain map, not a `%Row{}`: `Repo.insert_all/3` takes
  maps, and it does **not** fill timestamps for you — hence `inserted_at` as an argument rather
  than a clock read inside the mapper. `embedding` is simply absent from the map, which is what
  leaves the column NULL.
- **`to_message/1`** rebuilds the nested `%Scope{}` with `Scope.new/1`, which is idempotent over its
  own output, so a blank that normalised to `nil` on the way in stays `nil` on the way out.
- Roles cross the boundary through two explicit maps, never `String.to_atom/1` — and `Map.fetch!/2`
  on both, so a fourth role fails loudly instead of writing a `nil`.

Round-trip fidelity is the single most valuable test in the phase.

## 6.3 `Mem0.Messages` — the store

```elixir
@spec put([Message.t()]) :: {:ok, non_neg_integer()} | {:error, term()}
@spec for_run(Scope.t()) :: [Message.t()]
```

- **`put/1`** — one `Repo.insert_all/3` for the batch, stamping `inserted_at` once for all of them,
  and returning how many rows landed. `on_conflict: :nothing, conflict_target: :id` so that putting
  the same batch twice is a no-op rather than a constraint violation. That is the minimum needed to
  make the function safe to call twice; whether it is the *right* dedup policy is the overlap
  question, deferred.
- **`for_run/1`** — this run's messages ordered by `seq`, mapped back to core structs. It is the
  other half of the round trip and the thing that makes the write checkable.
- `put([])` is `{:ok, 0}` and issues no query.

## 6.4 Two things that come with writing content to disk

- **Ecto logs query parameters, and here those parameters are the transcript.** `insert_all` logs at
  `:debug`, dev runs at `:debug`, and that path defeats the parameter filtering in
  `config/config.exs` and breaks AGENTS.md's "never log prompts, completions or memory contents".
  Pass `log: false` on `put/1`'s insert specifically — not on the whole repo. `for_run/1` needs no
  silencing: its parameters are scope ids, and Ecto does not log result rows.
- **The embedding column is created and left NULL, not zero-filled.** pgvector's cosine distance
  against a zero vector is undefined; Postgres yields `NaN`, and `NaN` sorts *ahead* of every real
  distance in an `ORDER BY`. Zero placeholders would silently rank every message first the day
  someone writes the first similarity query. NULL is skipped, and it is honest about meaning "not
  computed". `768` is hardcoded in the migration with a comment naming
  `config :mem0, :embedder, :dimensions` as its source — a migration that changes shape with runtime
  configuration is not a migration. No HNSW or IVFFlat index; an index over NULLs is pure cost.

---

## Tests

`Mem0.MessagesTest` through `Mem0.DataCase`, `async: true`. Nothing else changes, because nothing
else calls this.

- a batch put and read back equals what went in — `said_at` microseconds intact, `nil` `app_id` and
  `run_id` still `nil`, `role` an atom again
- the same batch put twice is a no-op the second time, and `for_run/1` is unchanged
- `for_run/1` orders by `seq`, not by insertion order
- a second `run_id` in the same app is invisible to the first run's read
- `put([])` issues no query
- `embedding` reads back `nil`

## Exit criteria

- [ ] `Mem0.Messages.put/1` then `for_run/1` returns `Mem0.Core.Message` structs identical to what
      went in, microseconds included
- [ ] Nothing outside `Mem0.Messages` references `Mem0.Messages.Row` or `Mem0.Repo`
- [ ] No message content reaches any log at default dev configuration, Ecto's included
- [ ] `mix test.core` still passes with the Postgres container stopped
- [ ] `mix precommit` green

## Explicitly out of scope

**No wiring** — `Mem0.Ingest`, `Mem0Web.HooksController` and their tests are untouched, and no
message is persisted as a side effect of a hook. No dedup policy beyond "putting the same batch
twice does not raise". No embeddings computed and no embedder call. No memories table. No recall.
No retention, deletion or export. No pagination on `for_run/1`. No auth. No `lib/mem0.ex`.

## Open questions this phase deliberately leaves open

| Question | Why not here | Shape it lands on |
| --- | --- | --- |
| Overlapping `Stop` tails — the same message re-sent every turn | Wants a table to measure against, and a consumer that cares what is new | dedup on the id at insert, or resolution at extraction |
| Where the write is triggered from | A separate decision, and the one that costs `ingest_test.exs` its `async: true` | `Ingest.receive/2`, or the controller |
| Whether messages should carry embeddings at all | Only decidable once recall exists and its query is written | dropping the column, or filling it |
| Retention and deletion | Nothing to retain until now; the policy needs a second user to be real | a TTL per scope, or an explicit forget API |
| Whether `seq` should be assigned by the store rather than the client | Answerable now, but buys nothing while nothing writes | `offset` disappearing from `messages/3` |
