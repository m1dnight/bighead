# Attic — the graph channel (Bighead^g)

**Dropped 2026-08-21, before any of it was built.** Kept because the analysis is the reason to
revisit, not because the design is live. Nothing in `lib/` implements any of this.

## Why it was dropped

Upstream bighead abandoned it. As of v2.0.18 the OSS package ships no graph memory at all, and the
platform's "Graph Memory" is a different thing entirely: entities extracted with spaCy (typed
`PROPER | QUOTED | TOPIC | IDENTIFIER`, not `Person`/`City`), linked to the memories that mention
them, used as a ranking boost. Their own docs are explicit that it *"does not assign typed, labeled
relationships between entities"* — connections come from co-occurrence, not declaration.

The temporal reasoning the graph channel existed to provide moved to the base channel instead:
per-memory event intervals, a `state_key` linking successive versions of one evolving fact, and
supersession by setting `event_end` rather than deleting. That covers "where did she live before?"
without node resolution, without a threshold `t` to tune, without free-form relation labels drifting,
and without two extra full-context LLM calls per message pair.

What it gives up: exhaustive traversal for genuinely relational questions ("who does Alice work
with?"), which degrades from structure to resemblance. Interval containment survives, because both
facts carry intervals on memories and that is a SQL comparison.

## The design as it stood

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
Claude session, which is the fragmentation failure `t` is tuned against (notes §3.3: *"too high*
*fragments them"*). The field exists so that the answer has somewhere to live; this phase does not
pick it.

### Relations

```elixir
defmodule Bighead.Core.Graph.Relation do
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
  only "now" (§4.7.2). **Both ends are optional, and nil means *unbounded*, not**
  ** *unknown-so-assume-now*.** Most triplets state no start date — "I work at Acme" gives a `works_at`
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
to do about that (notes §7, Bighead^g: node type conflicts), so this phase makes sure the information
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
