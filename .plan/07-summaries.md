# Phase 7 — Summaries

**Goal:** the running conversation summary `S` (notes §2.1) — one function that regenerates it
from a run's whole message history in one LLM call, and a `summaries` table that stores what came
back. **Nothing calls either.** The controller is untouched, `stop.py` is untouched, no summary is
generated or stored as a side effect of anything, and extraction does not consume one.

The phase exists because extraction is capped by context. `Extract.facts/1` today reads a bare
message window; the paper's `φ(P)` reads `P = (S, recent, pair)`, and `S` is the half that resolves
pronouns and referents the window has already scrolled past. Before `Prompt` can be assembled,
something has to produce and hold an `S`. That something is this phase, standalone the way Phase 5
was. One reason is inherited from it: the prompt wants iterating against fixture transcripts in
IEx with no live session in the loop. The other is this phase's own — Phase 5's second reason was
"cannot break ingest", which nothing here can touch — and it is that the trigger, *when* to
refresh, on which event, at what staleness, is a separate decision already reserved for the `Stop`
route (its `@doc` says so). Building generation apart from its trigger means the cadence question
cannot hold the prompt work hostage.

**From scratch, every time.** Each regeneration reads the run's whole message history, never the
previous summary. The paper leaves the choice open (notes §7: "regenerated from the full history
each time or updated incrementally"), and the two shapes fail differently: incremental is cheaper
per refresh but folds `S` through itself forever — summaries of summaries shed truth a little per
generation, one bad completion propagates into every summary after it, and no test can bound how
far. Regeneration makes `S` a pure function of the stored messages: no fold-forward state to
corrupt, drift impossible by construction, and every summary explainable by pointing at its
inputs. That is correctness bought with tokens — each refresh costs proportional to session length
— and the trade is taken deliberately: expensive-and-right over cheap-and-quietly-wrong. It also
sharpens Phase 6's role rather than complicating it: `messages` is the single source of truth and
`S` is a derived view over it, recomputable at will. The ceiling this buys into — a session long
enough to outgrow the model's context window — is real and measurably distant; the open questions
carry the arithmetic.

## The whole pipeline

```
[Message.t()]  ──render──▶  prompt text  ──Bighead.LLM──▶  {"summary": s}  ──decode──▶  Summary.t()
    (pure)                                (boundary)                        (pure)

Summary.t() ──put──▶ summaries table ──latest──▶ Summary.t() | nil
                   (Bighead.Summaries, the only module that knows the table exists)
```

Three modules, two seams. `Bighead.Summarize` speaks only to the LLM port; `Bighead.Summaries` speaks
only to the Repo; neither knows the other exists. Composing them — check `stale?/3`, read the
run's messages, regenerate, put — is the wiring phase's whole job, and keeping them apart is what
makes each exercisable alone from IEx and each test suite independent of the other's dependency.

---

## 7.1 `Bighead.Core.Summary` — the pure half

The struct and `stale?/3` already exist and do not change. The module gains the same four
functions `Extraction` grew in Phase 5, because they are the same four jobs:

```elixir
@spec system_prompt() :: String.t()
@spec render([Message.t()]) :: String.t()
@spec request([Message.t()]) :: Bighead.LLM.request()
@spec decode(String.t(), Scope.t(), DateTime.t(), non_neg_integer()) ::
        {:ok, t()} | {:error, :malformed_summary}
```

- **`system_prompt/0`** — a module attribute, public for the Phase 5 reason: it is the artifact
  most worth diffing between iterations. Substance: distill a *coding agent's* whole session —
  who the user is as established so far, the project and its constraints, decisions taken and
  corrections issued, stated goals, where the work currently stands. Explicitly **not**: verbatim
  code or tool output, per-turn play-by-play, anything the next turn will make false. The output
  is capped at roughly 350 words, and under regeneration the cap is what makes `S` a summary at
  all — the model reads the whole history every time, so the only compression in the system is
  the one this sentence demands. Prompt-enforced only: a schema cannot measure length, and
  `decode/4` does not reject an overlong reply — verbosity is a quality bug to fix in the prompt,
  not a reason to destroy a usable summary.
- **`render/1`** — the messages in `seq` order as `role: content`, each truncated at `@max_chars`
  (2_000), and **no message-count cap**. Phase 5's cap kept the newest twenty and threw the rest
  away, which was fine there — extraction's input is disambiguation context — and would be wrong
  here, where every message dropped is a fact `S` can never state. Dropping the count cap is what
  regeneration makes safe: the render grows with the session, but nothing is ever silently
  excluded from the summary's view of history. The char cap stays and stays unshared with
  `Extraction`'s — it trims the one pathological pasted blob without losing the message, and each
  prompt's constants move when that prompt moves.
- **`request/1`** — system prompt, one user message holding `render/1`, and a
  `{"summary": string}` schema (`additionalProperties: false`, `summary` required). One place
  builds it so the `:live` test and the boundary send the same bytes.
- **`decode/4`** — `Jason.decode/1`, require `%{"summary" => binary}`, trim. Anything else —
  non-JSON, wrong shape, a non-binary — is `{:error, :malformed_summary}`, never a raise. **A
  blank summary is malformed too**: a blank distillation of a non-empty conversation is a failed
  generation whatever the transport said, and storing it would replace a usable `S` with nothing.
  The caller gets an error, the previous row simply stays latest, and a lagging `S` is survivable
  by design — "stale global context is acceptable; missing recent context is not" (notes §5,
  principle 7), because the recent window covers its gap.

No clock anywhere; `generated_at` and `through_seq` arrive as arguments. The layering test already
polices this module and keeps doing so.

## 7.2 `Bighead.Summarize` — the LLM boundary

`lib/bighead/summarize.ex`, a verb beside `Bighead.Ingest` and `Bighead.Extract`.

```elixir
@spec regenerate([Message.t()], keyword()) :: {:ok, Summary.t()} | {:error, term()}
def regenerate(messages, opts \\ [])
```

Named for what it does every time — the first generation is just the case where there was nothing
to replace. It takes the run's history as an argument and takes it on trust: passing less than the
whole history summarises less, and which messages constitute "the whole history" is the caller's
question (`Messages.for_run/1` will be the wiring phase's answer).

1. `[]` → `{:error, :no_messages}`, no call. A summary of nothing is not blank output, it is a
   call that should never be made.
2. Scope from `hd(messages).scope`, the Phase 5 argument verbatim.
3. `through_seq` is the **maximum** `seq` in the batch — `Enum.max_by`, not `List.last/1` — so the
   watermark cannot depend on what order a caller happened to hold the list in.
4. One `DateTime.utc_now/0` stamps `generated_at`.
5. The request is `Summary.request(messages)` unmodified; `opts` passes through to
   `Bighead.LLM.complete/2` untouched; port errors pass through unchanged.

What it deliberately does **not** do: read the `messages` table to find its own input, or write
its result anywhere. Threading input and output through arguments is what keeps this module
testable against `Bighead.LLM.Stub` alone, with no database in the test's dependency set.

## 7.3 `Bighead.Summaries` — the store

The Phase 6 pattern, smaller. A migration generated with `mix ecto.gen.migration
create_summaries`, a `Bighead.Summaries.Row` schema only `Bighead.Summaries` may reference, and public
functions that speak `Bighead.Core.Summary`:

```elixir
create table(:summaries) do
  add :user_id, :text, null: false
  add :app_id, :text
  add :run_id, :text
  add :text, :text, null: false
  add :through_seq, :integer, null: false
  add :generated_at, :utc_datetime_usec, null: false
  timestamps(type: :utc_datetime_usec, updated_at: false)
end

create index(:summaries, [:user_id, :app_id, :run_id, :through_seq])
```

```elixir
@spec put(Summary.t()) :: :ok | {:error, term()}
@spec latest(Scope.t()) :: Summary.t() | nil
```

- **Append-only, one row per regeneration — not an upsert.** Not because the previous text is an
  input — under regeneration it never is — but because append-plus-latest is the simplest write
  that is correct: a plain insert, no conflict target to invent on a table with no natural unique
  key, and a failed regeneration leaves the old row latest with no compensating code. The history
  costs a couple of kilobytes per row at the prompt's own length cap, and it is the record that
  makes two regenerations comparable when the prompt changes — which is exactly the iteration
  this phase exists to enable. This is *not* the memories table's
  append-mostly-with-supersession discipline; summaries are rebuildable derived data and need no
  audit semantics.
- **`app_id` and `run_id` stay nullable even though this phase only ever writes run-scoped
  rows.** `Scope`'s optional ids are nullable by construction and the exact-match read
  (`IS NULL` included) is inherited from `Messages` unchanged. Per-run-ness is a policy of the
  callers this phase deliberately does not have; `null: false` on `run_id` would encode that
  policy where only a migration can change it. App- and user-rung summaries are ruled out of this
  phase's scope, not out of the schema.
- **The default integer id stays in the store.** `Core.Summary` has no id field and gains none;
  the column exists because a table wants a primary key, and it never crosses the boundary.
- **`latest/1`** matches the scope exactly, `nil`s included, through the same `IS NULL` handling
  `Messages` uses — ordered by `through_seq` descending, id descending as tiebreak, `limit 1`,
  mapped back through `Scope.new/1` for the same idempotence guarantee `Messages.Row` leans on.
- **`put/1` passes `log: false`.** Summary text is distilled memory content — the exact class of
  data the redaction policy exists for. Same argument as `Messages.put/1`, same mechanism.
  `latest/1` needs no silencing: its parameters are scope ids.
- The layering test's persistence rule changes shape rather than just growing. Its current form —
  one flat list of persistence modules, one flat list of owners — was exact while there was one
  store, but adding a second to both lists would quietly permit `Bighead.Messages` to reference
  `Bighead.Summaries.Row` and the reverse. The rule becomes per-table ownership — a map from each
  `Row` to the one module allowed to name it, with `Bighead.Repo` reachable from the stores alone —
  so "only the store knows the table" stays a CI failure per table, not per layer.

## 7.4 What this phase measured and did not fix

`stale?/3` compares `through_seq` against a head `seq` in the same units — and Phase 4 made `seq`
an absolute transcript *line* number, while the `Summary` moduledoc and `@default_max_lag 10` still
speak in *messages*. Those units diverged more than intuition suggests. During Phase 6's hand-run
smoke test — not a repo test; a real 703-line session transcript from this machine's
`~/.claude/projects`, posted through the live hook path — 54 messages were stored, a machine-local,
order-of-magnitude ratio written down here precisely because it is reproducible nowhere else. At
that ratio ten lines of lag is under one conversational message, and a `max_lag` of 10 lines would
mark the summary stale on effectively every turn. Under regeneration the cadence question is also
the cost question — each refresh re-reads the whole history, so "how stale is too stale" directly
multiplies tokens spent per session. A second, smaller wrinkle sits beside it:
`Messages.lines_seen/1` returns a *count*, one past the head `seq`, so wiring it straight into
`stale?/3`'s `head_seq` argument overstates the lag by exactly one. This phase leaves `stale?/3`
untouched — it has no caller yet, and retuning a policy nobody executes would be motion, not
progress — but the wiring phase inherits all of it with the numbers attached rather than
discovering them live.

---

## Tests

- **Core, `async: true`, no db, no network:** `render/1` orders by `seq`, renders *every* message
  it is given — a batch past Phase 5's old cap size comes through whole — and truncates only by
  the char cap. `decode/4` has exactly two failure paths — unparseable and unusable — exercised with one
  input per enumerated shape: non-JSON, wrong shape, a non-binary `summary`, and blank after
  trim, plus a valid reply. Every failure is `{:error, :malformed_summary}`, never a raise.
- **Boundary, against `Bighead.LLM.Stub`:** the request carries the system prompt and the schema
  (assert via `Stub.calls/0`); `through_seq` is the max `seq` even when the list arrives
  shuffled; a canned reply becomes `{:ok, %Summary{}}` with the right scope and stamps; `[]`
  makes zero calls; a port error passes through.
- **Store, `Bighead.DataCase`, `async: true`:** put-then-latest round-trips the struct, microseconds
  and multi-line unicode text intact; `latest/1` picks the highest `through_seq`, not the last row
  inserted; a second run in the same app is invisible; a `nil` `app_id`/`run_id` scope reads back
  still `nil`.
- **One `@tag :live` test** running two real regenerations — one over the first half of a fixture
  conversation, one over all of it — asserting shape only. It exists to be *read*: the second
  summary should still carry the early facts, which is the property regeneration buys by
  construction and exactly what a stub cannot show.

## Exit criteria

- [ ] `Summarize.regenerate/1` on fixture-parsed messages returns a summary worth reading —
      checked by hand via the `:live` test
- [ ] A regeneration over a longer history still carries the early facts — the same `:live` test,
      read by hand
- [ ] `decode/4` never raises, on any of the malformed inputs above
- [ ] `Summaries.put/1` then `latest/1` returns the same `Summary`, and nothing outside
      `Bighead.Summaries` references `Bighead.Summaries.Row` — enforced by the layering test
- [ ] No summary text reaches any log at default dev configuration, Ecto's included — checked the
      Phase 6 way: a canary regeneration under `MIX_ENV=dev`, output grepped for the canary string
- [ ] `mix test.core` still passes with the Postgres container stopped
- [ ] `mix precommit` green

## Explicitly out of scope

**No wiring** — the `Stop` route keeps answering and doing nothing, `stop.py` is untouched, and no
regeneration happens as a side effect of any hook. No trigger and no cadence decision; `stale?/3`
is neither called nor retuned. No `Prompt` assembly and no change to `Extract` — `S` exists after
this phase but nothing reads it yet. No incremental refresh path, and no message-count cap on the
render: both are the shapes this phase decided against, and reintroducing either is a decision for
the phase that can measure what it buys. No summary embeddings: summaries are fetched by scope,
never by similarity. No summaries at the app or user rungs of the covering ladder — `S` is
per-run, the paper's shape. No retention, no deletion. No `lib/bighead.ex`.

## Open questions this phase deliberately leaves open

| Question | Why not here | Shape it lands on |
| --- | --- | --- |
| Trigger and cadence | Needs a call site; the `Stop` route is reserved for exactly this — and under regeneration cadence is also the cost knob (§7.4) | `stale?/3` against the head `seq` that `Messages.lines_seen/1` implies (§7.4: it returns a count, one past the head) on `Stop`, then `regenerate` off the request path |
| What `max_lag` counts | The units drifted (§7.4) and only a wired trigger can feel the difference | `stale?/3` taking a message count, or a line-denominated `max_lag` near 130 |
| A session that outgrows the context window | Measured over the 956 messages in this machine's transcripts: mean content 571 chars post-cap, 17% at the cap — so ~1,400 messages fill a 200K-token window at the mean, 400 in the cap-saturated worst case, versus 54 in the longest session yet; no such session exists to design against | chunked map-reduce summarisation, or incremental refresh reintroduced as an optimisation — now measurable against full regeneration as ground truth |
| Whether `S` feeds extraction next | That is `Prompt` and `φ(P)`, a phase of its own | `Extract.facts/1` taking a `Prompt.t()` |
| Harvesting Claude Code's own compact summaries | The transcript already contains `isCompactSummary` entries the normaliser drops — free, but written for a different reader and only at compaction time | an ingest rule routing them into `summaries` as a second source |
