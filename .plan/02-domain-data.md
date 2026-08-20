# Phase 2 — Domain data

**Goal:** every noun in Mem0 and Mem0^g exists as an Elixir type under `lib/mem0/core/`, with its
*shape* enforced at construction — required keys present, no field silently defaulted from another.
No persistence, no schemas, no migrations, no LLM, no embedder, no processes.

`new/1` enforces structure, not meaning. It does so because a struct that can be half-built produces
a nil check in every function that touches it. Semantic validation belongs at the public API — one
validation point, as the overview settles — and that is not this phase.

> The dependency claims below were executed against the real toolchain: `typed_struct` 0.3.0
> compiled under Elixir 1.20.2 / OTP 29 with `--warnings-as-errors`, its generated typespecs read
> back with `Code.Typespec`, and the failure modes named in 2.1 reproduced rather than assumed.
> Where a claim is a judgement call rather than a verified fact, it says so. Code snippets elide
> `alias` lines for readability; in real modules they are mandatory — see the Dialyzer trap in 2.1.

## Why data first, and why no persistence

The overview's sequencing principle is data before behaviour. Under immutability the wrong shape
produces compensating code in everything built on top of it, and everything built on top of it —
ingestion, search, the graph — is almost entirely functions over these structs.

Wiring schemas and queries in the same breath would make the boundary thick, leave the core
nonexistent, and commit the project to *domain shape == database shape* before a single decision
rule has been written. The shapes here are dictated by the paper (notes §2.2, §3.3) — the
ADD/UPDATE/DELETE/NOOP cascade, node resolution, interval containment. What Postgres wants is a
different question, asked by whoever first needs a fact to survive a restart.

Concretely this buys two things:

- **Ids stay opaque.** The core needs `Memory.id()` to be comparable and printable, nothing more.
  UUIDv7 or bigserial can then be decided without touching a line of core code.
- **The embedding dimension stops blocking anything.** It is a question about the embedder, and
  with no `vector(N)` column to declare, it stays one.

---

## 2.1 Layout and rules

```
lib/mem0/core/          pure structs and functions — no Ecto, no Repo, no processes, no IO
lib/mem0/core/graph/    the Mem0^g half
```

Three rules that make the phase checkable rather than aspirational.

**No `Ecto`, `Repo`, `Req` or `GenServer` anywhere under `core/`.** Not grep — grep misses
`apply/3`, aliased calls and macro-generated references. `mix xref graph --sink Ecto --format plain`
gives the real answer, and a test that enumerates `Mem0.Core.*` from
`:application.get_key(:mem0, :modules)` and asserts none of them reach the forbidden set makes it a
CI failure rather than a habit.

**No struct under `core/` has an `embedding` field.** Similarity is computed by whatever holds the
vectors; what the decision rules consume is the *score*. Candidates reach the core as
`{score, struct}` two-tuples — fixed-size and positional, so a decision rule pattern-matches them in
one line. The payoff is at test time: a fixture for the update decision is
`{0.91, %Memory{content: "User lives in SF"}}`, not a 1536-element list.

`Mem0.Core.Scored` owns that shape rather than leaving it a prose convention, because it is the most
reused type in the system — the `s` update candidates (notes §2.2), node resolution's scored nodes
(§3.3), triplet search results (§3.4) — and Dialyzer cannot check a shape with no `@type`:

```elixir
@type t(a) :: {float(), a}
@spec rank([t(a)]) :: [t(a)] when a: var     # descending by score
@spec above([t(a)], float()) :: [t(a)]       # threshold — `t` for node resolution
```

`rank/1` exists because the tuple does **not** sort usefully on its own. Erlang term order sorts
ascending — worst candidate first — and ties fall through to comparing the second element, a map, by
term order, which is arbitrary. One `rank/1` beats three call sites each rediscovering
`sort_by(&elem(&1, 0), :desc)`.

**No `DateTime.utc_now/0` inside a core function.** Time arrives as an argument. Every timestamp
field is set from the constructor's input, never by the constructor itself. This is what makes the
interval and staleness predicates testable without `Process.sleep`, and it is a precondition for a
`Clock` port later rather than an afterthought.

### Dependencies

```elixir
{:typed_struct, "~> 0.3.0"},
{:stream_data, "~> 1.2", only: [:dev, :test]}
```

`stream_data` is for the interval predicates in 2.7. It needs `:dev` as well as `:test` — 01 §1.6
was bitten by exactly this with `dialyxir`, because `preferred_envs: [precommit: :test]` makes env
availability a real constraint rather than a formality.

Verified about `typed_struct` 0.3.0: it compiles clean under Elixir 1.20.2 / OTP 29 with
`--warnings-as-errors` and generates a real `t()`. Four things that are *not* obvious and were
reproduced rather than assumed:

- **It generates no constructor.** Only `__struct__/0,1`. So every module gets a hand-written
  `new/1` taking a keyword list and delegating to `struct!/2`, with any real construction behaviour
  — normalising a name, rendering a triplet — living there rather than in the caller.
- **`struct!/2` does not reject nil values.** `@enforce_keys` checks key *presence*, not value:
  `struct!(Scope, user_id: nil)` succeeds. Any field where nil is meaningless needs an explicit
  check in `new/1`. For `Scope.user_id` that is not pedantry — see 2.2.
- **Optional fields are written `field :app_id, String.t(), enforce: false`**, never
  `String.t() | nil`. Under a block-level `enforce: true` the library appends the `| nil` itself, and
  writing both yields `(String.t() | nil) | nil`. Both forms compile clean, so nothing catches it.
- **A field with a `default:` inside an `enforce: true` block opts out of enforcement and stays
  non-nullable in the typespec** — which is what `source_message_ids` in 2.4 relies on. Note the
  runtime gap: `struct!` still accepts an explicit `nil` there, and only Dialyzer objects.

**The alias trap, and why it matters here.** A snippet writing `field :scope, Scope.t()` inside
`Mem0.Core.Fact` compiles clean *even with `--warnings-as-errors`*, because Elixir does not resolve
remote types at compile time. It means `Elixir.Scope.t()`, which does not exist. Only Dialyzer
catches it, reporting `Unknown types: 'Elixir.Scope':t/0`. Same for a bare local `id()` used as a
field type — that is a hard compile error unless the module declares `@type id`. Since this phase
puts Dialyzer on the critical path, both are real defects rather than shorthand.

*Judgement: `typed_struct`'s last release was 2022 and it remains the most-used option*
*(9.5M downloads against `typed_structor`'s 16k). The staleness is acceptable because the library*
*generates code at compile time and has no runtime surface to rot — the generated beam contains no*
*reference to it, so it can be declared `runtime: false`. If it ever breaks, `typed_structor` (~> 0.6,*
*March 2026) has a byte-identical field DSL; migration is two renames, `TypedStruct` →*
*`TypedStructor` and `typedstruct` → `typed_structor`. It generates no `new/1` either.*

### The whole set

| Module                       | Role                                              | Source           |
| ---------------------------- | ------------------------------------------------- | ---------------- |
| `Mem0.Core.Scope`            | write address — user / app / run                  | README           |
| `Mem0.Core.ScopeQuery`       | read filter over the same three levels            | README           |
| `Mem0.Core.Scored`           | `{score, thing}` — the shape candidates arrive in | notes §2.2, §3.3 |
| `Mem0.Core.Message`          | one message in a conversation                     | notes §2.1       |
| `Mem0.Core.Summary`          | `S`, the conversation summary                     | notes §2.1       |
| `Mem0.Core.Prompt`           | `P = (S, {m_{t-m}..m_{t-2}}, m_{t-1}, m_t)`       | notes §2.1       |
| `Mem0.Core.Fact`             | a candidate `ω` from `Φ`, not yet reconciled      | notes §2.1       |
| `Mem0.Core.Extraction`       | `Ω`, the output of one `Φ` call                   | notes §2.1       |
| `Mem0.Core.Memory`           | a reconciled fact the system holds                | notes §2.2, §2.4 |
| `Mem0.Core.MemoryOperation`  | ADD / UPDATE / DELETE / NOOP                      | notes §2.2, §2.3 |
| `Mem0.Core.Decision`         | an operation plus why it was chosen               | notes §7         |
| `Mem0.Core.Graph.EntityRef`  | an extracted `(name, type)`, unresolved           | notes §3.2       |
| `Mem0.Core.Graph.Triplet`    | an extracted `(source, label, destination)`       | notes §3.2       |
| `Mem0.Core.Graph.Extraction` | the output of the two-stage graph extractor       | notes §3.2       |
| `Mem0.Core.Graph.Entity`     | a resolved node                                   | notes §3.1, §3.3 |
| `Mem0.Core.Graph.Relation`   | a resolved edge with a validity interval          | notes §3.3, §4.7 |
| `Mem0.Core.Graph.Resolution` | node resolution's verdict for one `EntityRef`     | notes §3.3       |
| `Mem0.Core.Graph.Operation`  | add-relation / invalidate / noop                  | notes §3.3       |
| `Mem0.Core.Graph.Decision`   | a graph operation plus why it was chosen          | notes §4.5       |

---

## 2.2 Scope

The address of everything. Per the README: user id (OS user), app id (repo or directory), run id
(Claude session).

```elixir
defmodule Mem0.Core.Scope do
  use TypedStruct

  typedstruct enforce: true do
    field :user_id, String.t()
    field :app_id, String.t(), enforce: false
    field :run_id, String.t(), enforce: false
  end
end
```

**The trap to head off now:** `nil` means two different things depending on direction.

- On **write**, `run_id: nil` means *this fact is not tied to a session* — general knowledge about
  the user. A real, deliberate value.
- On **read**, `run_id: nil` means *any session*.

Same shape, opposite semantics, one bug away from a session-local scratch note leaking into every
project the user works on. So there are two types:

- `Mem0.Core.Scope` — a write address. `user_id` required *and non-nil*; nil `app_id`/`run_id` means
  "general". `user_id: nil` would address every user at once, which is the one value that must be
  unconstructible, and `struct!/2` will not do that for us.
- `Mem0.Core.ScopeQuery` — a read filter. `nil` at a level means *any value at that level*.

`Scope.covering/1` takes the concrete address a read happens at and returns `[ScopeQuery.t()]` — the
ladder that read should see, **widening**: exact run, then app-level (any run), then user-level (any
app). Search needs it to rank a session-specific memory above a global one; any surface answering
"what does mem0 know here?" needs it too.

It lives on `Scope`, not on `ScopeQuery`, and that placement is the whole point. Generating the
ladder requires reading a nil as *"this level does not apply"*, which is only true on the write side.
Asking a `ScopeQuery` to do it would mean interpreting a nil that already means "any" as if it meant
"none" — the exact ambiguity this pair exists to make inexpressible.

**A deviation from the paper, stated rather than smuggled.** Notes §2.4 scopes memory
*per participant*: each speaker has a namespace and both are supplied at answer time. `Scope` is
user/app/run — a different axis. For Claude Code there is one human and one assistant, and only the
human's facts are worth keeping, so participant collapses into `user_id`. If a second human
participant ever appears, that is the axis that has to split.

---

## 2.3 Conversation context

The extraction prompt is `P = (S, {m_{t-m}..m_{t-2}}, m_{t-1}, m_t)` (notes §2.1). Three structs
assemble it:

| Struct              | Fields                                                           |
| ------------------- | ---------------------------------------------------------------- |
| `Mem0.Core.Message` | `id`, `scope`, `role`, `content`, `said_at`, `seq`               |
| `Mem0.Core.Summary` | `scope`, `text`, `generated_at`, `through_seq` — plus `stale?/2` |
| `Mem0.Core.Prompt`  | `scope`, `summary` (optional), `recent`, `pair`, `at`            |

`Message` needs **both** `id` and `seq`, and they are not the same thing. `seq` is the ordering
within one conversation — what `Summary.through_seq` compares against and what selects the `m`
recent messages — and it is meaningless outside that conversation. `id` is identity, opaque like
`Memory.id()`, and it is what `Fact.source_message_ids` stores so provenance survives being read
back in a different session.

`Summary` carries `scope` because it is fetched *before* the `Prompt` that will hold it exists. A
summary with no address cannot be looked up, and `Prompt.scope` is assembly-time, too late.

`Prompt.summary` is optional. At the head of a new conversation there is no `S` yet, and the design
explicitly tolerates its absence and staleness (notes §2.1: *"`S` is allowed to be stale"*). Under a
block-level `enforce: true` it would otherwise be mandatory.

`Prompt.pair` is the new `(m_{t-1}, m_t)` exchange and `Prompt.recent` is the preceding window. They
are separate fields, not one list, because the paper's central extraction constraint is that facts
come **from the new pair only** while the rest is disambiguation context (notes §2.1). A single
concatenated list makes that distinction a prompt-template convention; two fields make it a type.

`role` is `:user | :assistant | :system` — a closed set, validated at the boundary before it reaches
the core, so atoms are safe.

`Summary.stale?/2` takes the summary and the current head `seq`, so the refresh policy is a pure
comparison rather than a timer buried in a worker. The paper's cadence is unspecified (notes §6);
this puts the decision in one testable function whatever cadence is eventually chosen.

---

## 2.4 Base memory

The candidate/identified split, which is the spine of the base channel:

| Type                        | What it is                                   | Identified? |
| --------------------------- | -------------------------------------------- | ----------- |
| `Mem0.Core.Fact`            | a candidate `ω` from `Φ`, not yet reconciled | no          |
| `Mem0.Core.Extraction`      | the set `Ω` from one `Φ` call                | —           |
| `Mem0.Core.Memory`          | a reconciled fact the system holds           | yes         |
| `Mem0.Core.MemoryOperation` | what to do                                   | —           |
| `Mem0.Core.Decision`        | what to do, and why                          | —           |

```elixir
defmodule Mem0.Core.Fact do
  use TypedStruct

  typedstruct enforce: true do
    field :content, String.t()
    field :scope, Scope.t()
    field :extracted_at, DateTime.t()
    field :event_time, DateTime.t(), enforce: false
    field :source_message_ids, [Message.id()], default: []
  end
end
```

`Memory` is `Fact` plus `id`, `created_at` and `updated_at`. The step from one to the other is
**identification**, not persistence — a `Memory` is a fact the system has committed to and can refer
to by name. That framing is what lets this phase define both without a database.

`@type id :: String.t()`. Opaque **by convention, not by `@opaque`** — `Memory.id()`, `Entity.id()`
and `Relation.id()` are all `String.t()` and mutually substitutable, so Dialyzer will not catch a
crossed id. *Judgement: `@opaque` would catch it, at the cost of every module that touches an id*
*needing an accessor. Not worth it at this size; revisit if a crossed id ever actually happens.*

**`Mem0.Core.Extraction`** — the output of one `Φ` call: `scope`, `prompt_at`, `facts :: [Fact.t()]`,
`source_message_ids`. `Ω` is a noun in the paper and it needs a shape, because the paper's update
phase is a per-fact loop with *no coordination between facts from the same pair*: two candidates may
target the same retrieved memory, or one may ADD something a later one would UPDATE (notes §7).
Deciding that policy is not this phase's job. Having one struct to hang it on is.

**`Mem0.Core.MemoryOperation`** holds the type and its parsing:

```elixir
@type t ::
        {:add, Fact.t()}
        | {:update, Memory.id(), Fact.t()}
        | {:delete, Memory.id()}
        | :noop
```

`{:update, id, Fact.t()}` reads exactly as Algorithm 1 specifies: the id survives, the content is
replaced. Both `UPDATE` and `DELETE` carry an id because the algorithm resolves both against a
*specific* one of the `s` retrieved candidates, not against the store at large (notes §2.3).

Algorithm 1's replacement is also **conditional** —
`if InformationContent(f) > InformationContent(m_i)` — so the LLM can choose `UPDATE` and the correct
outcome still be nothing. The paper never defines
`InformationContent` (notes §7: token count, proposition count and an LLM judgement are all plausible
and behave differently).

That guard is a pure comparison over two contents, so it belongs in the core. If the boundary
evaluated it, the boundary would be deciding rather than performing, and the overview's settled pivot
would be broken. `MemoryOperation` therefore takes `richer?/2` as an injectable predicate —
`(Fact.t(), Memory.t()) -> boolean()` — defaulting to something this phase can test, so an LLM
judgement can be substituted later without moving the guard. **An `UPDATE` that fails the guard
degrades to `:noop` inside the core**, so the boundary never receives an operation it should not
perform.

**`Mem0.Core.Decision`** is a struct wrapping an operation with its audit metadata: `operation`,
`reason`, `considered_ids`, `decided_at`. **The core's update phase returns `Decision.t()`, not a
bare `MemoryOperation.t()`** — the overview names the pivot by its most important field; this refines
that rather than contradicting it. The boundary performs `decision.operation` and keeps the rest.

The LLM's justification is a property of the *decision*, not of the fact, and it is what makes a
deleted memory explainable — the audit trail notes §7 flags as absent. `considered_ids` records which
of the `s` retrieved candidates were in front of the model, including on a `:noop`, where it is the
only evidence the decision happened at all. On a `:delete` it also carries the id of the memory that
replaced it, which is the ordering signal notes §4.3(b) observes base Mem0 generates and then throws
away.

### Ids in prompts, and who maps them back

Never hand memory ids to the LLM. The update phase presents the `s` retrieved candidates as `1..s`,
and `MemoryOperation.parse/2` maps the chosen ordinal back to an id —
`parse(model_output, candidates)`, where `candidates` is the ordered list the boundary retrieved. The
mapping is a pure list lookup, so it stays in the core; the boundary supplies the list and performs
the result.

`parse/2` returns `{:ok, t()} | {:error, term()}` and never raises. It is the one function in this
phase reading input the core did not produce — an ordinal outside `1..s`, a missing operation key, an
unrecognised operation name are all *expected* values from a model, not programmer errors, and the
settled "the core trusts its input" rule does not extend to model output. It does turn `"ADD"` into
`:add`; that is the only place this phase mints an atom from model output, and it is safe because the
set is closed and matched literally, never via `String.to_atom/1`.

### Timestamps and provenance under UPDATE

`Memory` carries four timestamps and only two of them are clocks in the 2.6 sense.

`extracted_at` is inherited from the `Fact` and records which `Φ` call produced the *current
content*; after an id-preserving UPDATE it names a later pair than `created_at` does, which is
correct and is the point. `updated_at` is the **recency signal** the answer prompt's "prioritise the
most recent" rule reads (notes §2.5) — not `created_at`, or an updated memory would lose to a fresh
one repeating stale information. On ADD they are equal.

`source_message_ids` **accumulates** across UPDATE rather than being replaced. After an update the
content derives from both pairs, and a provenance list naming only the most recent one cannot explain
the memory it points at. The field answers notes §7's flagged gap — *"nothing is said about linking a
memory back to the messages that produced it"* — which is the only reason it exists.

---

## 2.5 Graph

The same candidate/identified split, one level richer because resolution sits between the two:

| Candidate (from the LLM)                                                             | Identified                                                                                               |
| ------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------- |
| `Graph.EntityRef` — `name`, `type`                                                   | `Graph.Entity` — `id`, `scope`, `name`, `type`, `aliases`, `event_time`, `event_precision`, `created_at` |
| `Graph.Triplet` — `source :: EntityRef.t()`, `label`, `destination :: EntityRef.t()` | `Graph.Relation` — resolved ids plus a validity interval                                                 |
| `Graph.Extraction` — `entities`, `triplets`                                          | —                                                                                                        |

`type` and `label` are `String.t()`, **never atoms** — they come from model output and the atom table
is never GC'd. Settled in the overview; restated because a `String.to_atom/1` in a JSON decoder is
precisely how this gets violated by accident.

`Graph.Extraction` exists because extraction is a **two-stage** pipeline (notes §3.2): stage 1
produces entities with their types, stage 2 derives relations over entity *pairs*. Without a
container for stage 1's output, the entity types have no path into node resolution, which otherwise
only ever sees a triplet.

### Entities

The paper uses embeddings for two distinct jobs and the notes are explicit that they must not be
conflated (§5, principle 5): **node** embeddings drive entity resolution and query anchoring;
**triplet-text** embeddings drive holistic query matching. Neither vector lives in the core, but both
need their *input* visible here.

`Entity.name` is the canonical surface form the node embedding is computed over. `Entity.aliases`
holds the other forms that resolved onto it ("SF", "San Fran") and never re-embed. Keeping the
distinction explicit is what makes a bad merge debuggable — the failure mode the notes call
*actively harmful* (§4.5), because it fabricates relationships that were never stated — since
debugging one means asking which text produced the vector that matched.

`event_time` and `event_precision :: :instant | :day | :month | :year | nil` are nil for ordinary
entities and populated for **date nodes**. The paper treats dates as entities (notes §3.2, §4.3), and
a date node whose date lives only in its `name` string is not a date to any function in this system.
Interval containment — *"was I at Acme when the layoffs happened?"*, the query §4.4 uses to show what
the graph is *for* — compares a `Relation`'s interval against a date node's instant. Without a parsed
field, that comparison has to happen at query time by re-parsing LLM-written prose. Precision is not
optional either: `"Mar 2023"` is a month, and flattening it to `2023-03-01T00:00:00Z` answers a
containment question wrongly whenever the boundary falls inside March.

`Entity.scope` is where the entity resolution scope question will be settled, and it is left open on
purpose — see the table at the end. Run-addressed entities make `San Francisco` a new node every
Claude session, which is the fragmentation failure `t` is tuned against (notes §3.3: *"too high
fragments them"*). The field exists so that the answer has somewhere to live; this phase does not
pick it.

### Relations

```elixir
defmodule Mem0.Core.Graph.Relation do
  use TypedStruct

  @type id :: String.t()

  typedstruct enforce: true do
    field :id, id()
    field :scope, Scope.t()
    field :source_id, Entity.id()
    field :label, String.t()
    field :destination_id, Entity.id()
    field :valid_from, DateTime.t(), enforce: false
    field :valid_to, DateTime.t(), enforce: false
    field :superseded_by_id, id(), enforce: false
    field :triplet_text, String.t()
    field :source_message_ids, [Message.id()], default: []
    field :created_at, DateTime.t()
  end
end
```

Three fields doing specific work, each traceable to a line in the notes:

1. `valid_from` / `valid_to` answers "before", "during" and "as of"; an `is_valid` boolean answers
   only "now" (§4.7.2). **Both ends are optional, and nil means *unbounded*, not
   *unknown-so-assume-now*.** Most triplets state no start date — "I work at Acme" gives a `works_at`
   edge with no `valid_from` — and filling it from the utterance time is exactly the clock collapse
   2.6 forbids and §4.7.5 warns breaks the answer prompt. It would also corrupt the containment query
   above: an edge whose `valid_from` really means "we found out on Tuesday" answers "was I at Acme in
   March?" wrongly. Predicates: `valid_at?/2`, `current?/2`.
2. `superseded_by_id` is the *dateless ordering signal* — that relation A was replaced by relation B
   records that A came first even when neither carries a date (§4.3b). It is set during the
   invalidate step, not at construction, because of the id problem below.
3. `triplet_text` is the rendered `"Alice lives_in San Francisco"`. Rendering is a pure function
   (`Relation.render/3` over the two entity names and the label) and belongs here; what later embeds
   that string does not. Storing the rendered text rather than re-deriving it means the embedding
   always has visible provenance.

**Relations are never deleted, only invalidated** — settled in the overview. There is no
`Relation.delete`; the only removal-shaped operation sets `valid_to` and `superseded_by_id`. Base
memory deletes, the graph invalidates, and that asymmetry *is* the graph's temporal advantage
(§4.7.1). The type system should make violating it awkward.

### Decision types

- `Graph.Resolution` — `{:existing, Entity.id(), EntityRef.t()} | {:new, EntityRef.t()}`, the pure
  output of node resolution given scored candidates and threshold `t`.
  The `:existing` arm carries the candidate ref forward rather than dropping it. The ref's surface
  form is what `aliases` records, and its `type` is what lets someone notice that this extraction
  called `Acme` an `Organization` where the stored node says `Company`. The paper does not say what
  to do about that (notes §7, Mem0^g: node type conflicts), so this phase makes sure the information
  survives long enough for someone to have the choice. Discarding it at resolution time is a decision
  made by omission, and it is the same mistake `aliases` exists to avoid one field over.
- `Graph.Operation` —
  ```elixir
  @type superseded_by :: {:existing, Relation.id()} | {:new, Triplet.t()} | :none

  @type t ::
          {:add_relation, Resolution.t(), String.t(), Resolution.t()}
          | {:invalidate, Relation.id(), DateTime.t(), superseded_by()}
          | :noop
  ```
  The `{:new, …}` arm is not cosmetic. In the case that motivates the whole mechanism — "I moved to
  New York" invalidates `lives_in SF` (§4.4) — the superseding edge is created in the *same* decision
  pass, so its id does not exist when the core decides. A bare `Relation.id()` there is
  unconstructible; filling it with `nil` silently discards the ordering signal that is
  `superseded_by_id`'s only reason to exist. The boundary resolves `{:new, triplet}` to the id it
  just assigned. The core never emits an id it did not receive — the same discipline that makes
  `{:add, Fact.t()}` carry no id on the base side.
  `{:add_relation, …}` takes the two resolutions and the label rather than the whole triplet: the
  resolutions already carry both endpoint refs, so passing the triplet too would be a second copy.
- `Graph.Decision` mirrors `Decision` for the graph channel, for the same reason and one stronger
  one: invalidation is an LLM resolver judgement (notes §3.3), a wrongly-invalidated edge is silent
  where a wrongly-deleted memory is at least missing, and the graph's characteristic failure — a bad
  node merge — is *actively harmful*. Both channels record why.

---

## 2.6 The three clocks

The notes (§4.1) are emphatic that collapsing these breaks the answer prompt. Where each lives:

| Clock                        | Field                                                                    |
| ---------------------------- | ------------------------------------------------------------------------ |
| Utterance — when it was said | `Message.said_at`, `Memory.created_at`, `Entity.created_at`              |
| Event — when it happened     | `Memory.event_time`, `Fact.event_time`, `Entity.event_time` (date nodes) |
| Validity — when it was true  | `Relation.valid_from` / `valid_to`                                       |

All are `DateTime.t()` in UTC, all supplied as input. **A struct carrying two of these must never
default one from the other.** `event_time` stays nil when the fact states no event time, and nil
means *unknown*, not *same as utterance time*. The same rule is why `Relation.valid_from` is
optional.

`Memory.extracted_at` and `Memory.updated_at` are not clocks in this sense; 2.4 says what each is
for.

---

## 2.7 Tests

The point of this phase is that its test suite needs nothing: no database, no network, no sandbox,
no `Process.sleep`. Making that *checkable* takes two lines Phase 1 did not need, because `mix test`
currently runs `ecto.create` and `ecto.migrate` first (mix.exs) and the Phase 1 vector round-trip
test checks out a sandbox connection:

- tag the Phase 1 vector round-trip test and the generated Phoenix cases `@tag :db`
- add `test.core: ["test --exclude db"]`, alongside the `test.live` alias 01 §1.4 already
  established, and *without* the `ecto.create`/`ecto.migrate` prefix

**`mix test.core` passes with the Postgres container stopped.** That is the exit criterion for the
layering, not a nice-to-have. Bare `mix test` still runs everything and still needs the container.

What is worth testing:

- **Constructors enforce.** `new/1` without a required key raises via `struct!/2`.
  `Scope.new(user_id: nil)` *also* raises — `struct!/2` alone does not do that, so `Scope.new/1`
  carries an explicit non-nil check. It is the one field where nil is not a narrower address but a
  wildcard one, which is the failure 2.2 exists to prevent. Normalisation in `new/1` is idempotent.
- **`Scope.covering/1`** returns the ladder in widening order — run, then app, then user — and drops
  the rungs a nil `run_id` or `app_id` makes meaningless.
- **`Relation.valid_at?/2` and `current?/2`** at the interval edges, which are the whole feature:
  open-start (`valid_from: nil`), open-end, fully open, closed, and a query instant exactly on each
  boundary.
- **The UPDATE guard** degrades `{:update, …}` to `:noop` when the candidate is not richer, with
  `richer?/2` injected.
- **`MemoryOperation.parse/2`** returns `{:error, _}` rather than raising on malformed model output,
  including an ordinal outside `1..s`.
- **`Summary.stale?/2`** across the threshold.
- **`Scored.rank/1`** puts the highest score first, and is stable on ties.
- **`Relation.render/3`** is deterministic — the same triplet always produces the same string, since
  an embedding will later be keyed on it.

Fixtures go in `test/support/` as plain functions: `*_fields` taking an `overrides` keyword list,
`Keyword.fetch!` inside so a missing field raises immediately, and a `__using__` that aliases and
imports them so test files open with one line. Every test file is `async: true` — there is nothing
shared to contend over.

The interval predicates are a natural fit for property-based testing over generated instants and
intervals, and this is the cheapest phase in the project to try it in. *Judgement: worth a try, not*
*worth blocking on.*

---

## Exit criteria

- [ ] `mix xref graph --sink Ecto` reports nothing under `Mem0.Core.*`, and a test asserts the same
      for `Repo`, `GenServer` and HTTP clients
- [ ] No core struct has an `embedding` field, and no core function calls `DateTime.utc_now/0`
- [ ] `mix test.core` passes with the Postgres container stopped; every test file is `async: true`
- [ ] `mix dialyzer` reports zero warnings — and **`dialyzer` goes back into the `precommit` alias in
      this phase**. 01 §1.6 kept it out because with zero domain code it found nothing and slowed the
      loop AGENTS.md tells every agent to run constantly, and it named the condition for revisiting:
      *once a real functional core exists*. This is that core, and without Dialyzer the alias trap in
      2.1 goes uncaught. Update AGENTS.md and the README note that currently says the opposite, in
      the same commit, as 01 §1.9 requires.
- [ ] `mix precommit` green

## Explicitly out of scope

No Ecto schemas, no migrations, no `Repo`, no queries. No changesets — semantic validation belongs at
the public API. No embedding generation, no prompts, no LLM calls, no retrieval, no processes.

## Open questions this phase deliberately leaves open

Each of these is a gap the paper leaves open (notes §6, §7). This phase gives each one a *shape* to
land on without choosing the answer. Naming them here is what stops them being decided by accident,
by an omission nobody notices.

| Question                                                                         | Why not here                                                            | Shape it lands on              |
| -------------------------------------------------------------------------------- | ----------------------------------------------------------------------- | ------------------------------ |
| Persistence — schemas, migrations, the store boundary                            | Naming a table now fixes the domain shape to a database shape           | the opaque `id()` types        |
| Coordination between the facts of one `Extraction`                               | The paper's update loop is per-fact with no coordination at all         | `Extraction`                   |
| What `InformationContent` measures                                               | Never defined; token count and an LLM judgement behave differently      | `richer?/2`                    |
| Summary refresh cadence                                                          | "Periodically"; needs a running pipeline to tune against                | `Summary.stale?/2`             |
| `s`, and the `SemanticallySimilar` cutoff                                        | Tuning, and it needs a real embedder to tune with                       | `Scored.above/2`               |
| Node resolution threshold `t`                                                    | Same — too low merges distinct entities, too high fragments them        | `Scored.above/2`               |
| Entity resolution scope — user/app vs run                                        | Run-addressing fragments the graph, but the call wants measurement      | `Entity.scope`                 |
| Which relations are single-valued (`lives_in` supersedes, `visited` accumulates) | Nothing in the paper distinguishes them                                 | `Graph.Operation`              |
| Conflict-detection scope — which edges are even candidates for invalidation      | The paper describes the resolver, not how candidates are found          | `Graph.Operation`              |
| Node type conflicts                                                              | Unaddressed by the paper; the information at least survives resolution  | `Resolution`'s `:existing` arm |
| Retrieval result structs — fusing semantic, lexical and entity-centric channels  | The shape is discovered by building the channels, not by guessing early | —                              |

The last row is deferred for a different reason than the rest. The others have a shape and lack a
value; that one lacks a shape entirely. Inventing one now would mean guessing at a merge policy the
paper does not specify (notes §7), while the README's own search plans — a separate lexical index
alongside the vector one — are still moving.
