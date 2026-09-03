# Bighead / Bighead^g — Conceptual Notes for Implementation

Source: Chhikara, Khant, Aryan, Singh, Yadav — *Bighead: Building Production-Ready AI Agents
with Scalable Long-Term Memory* (arXiv:2504.19413v1, 28 Apr 2025).

Scope: the theoretical and architectural content. Benchmark tables, baseline comparisons and
latency measurements are omitted except where a result directly informs a design decision.

**Both architectures are covered in full.** The paper presents Bighead and Bighead^g as
complementary, and Bighead^g's own answer-generation prompt consumes the output of *both*
pipelines. Bighead is a prerequisite for the graph variant, not an alternative to it.

---

## 1. Problem framing

LLMs have fixed context windows and no persistent memory: once information falls outside the
window, the model effectively "resets". Two reasons a bigger window does not solve this:

1. **Volume.** Relationships that develop over weeks or months exceed any window.
2. **Thematic discontinuity.** Real conversations wander. A dietary preference stated hours
   ago sits buried under unrelated programming chat. Full context forces the model to reason
   through mountains of irrelevant tokens, and attention degrades over distant tokens — long
   context does not guarantee *use* of the relevant span.

The requirement is therefore not "more context" but a memory system that **selectively
stores** salient information, **consolidates** related concepts, and **retrieves** only what
is relevant.

Two architectures are proposed:

- **Bighead** — dense natural-language memories, extracted incrementally from message pairs and
  reconciled against existing memories through ADD / UPDATE / DELETE / NOOP.
- **Bighead^g** — a **directed labeled graph** of entities and relationships, built with the same
  incremental philosophy, aimed at reasoning that traverses relational paths and at temporal
  reasoning over superseded facts.

### 1.1 How the two relate

| | Bighead | Bighead^g |
|---|---|---|
| Unit of storage | natural-language fact | entity node / relation edge |
| Reconciliation | four-way LLM operation choice | node resolution + conflict resolution |
| Removal | `DELETE` — hard removal | invalidation — edge retained, marked obsolete |
| Retrieval | vector similarity over memories | entity-centric traversal + triplet vector search |
| Footprint | ~7k tokens per conversation | ~14k tokens (roughly double) |
| Strongest at | single-hop, multi-hop | temporal, open-domain |
| Weakest at | temporal ordering of superseded facts | adds nothing on single-hop / multi-hop |

They run over the **same conversation** and are merged only at answer time. The paper's
Bighead^g prompt supplies, per participant, a `Memories for user {id}` section (base) *and* a
`Relations for user {id}` section (graph). Neither replaces the other.

The results are worth internalising because they cut against intuition: the graph does **not**
help multi-hop questions, which is exactly where relational structure sounds most useful. Dense
natural-language memory already carries enough representational richness to synthesise across
sessions. The graph earns its cost on **temporal** questions — because it keeps superseded
edges — and on open-domain breadth.

---

## 2. Bighead (base)

Two phases, running **per message pair** rather than per session. This incremental processing
paradigm is the load-bearing design decision: memory stays current during an ongoing
conversation instead of being batch-built afterwards, and newly added memories are immediately
usable.

### 2.1 Extraction phase

**Trigger.** A new message pair `(m_{t-1}, m_t)` — typically a user message plus an assistant
response, i.e. one complete interaction unit. The paper also supports two human participants.

**Context assembled for the extractor.** Two complementary sources, each covering the other's
blind spot:

- **S** — a conversation summary retrieved from the database, encapsulating the semantic
  content of the *entire* conversation history. Provides global thematic understanding.
- **{m_{t-m}, …, m_{t-2}}** — the last `m` messages preceding the new pair. Provides granular
  temporal context holding details the summary has not yet consolidated. `m` is a
  hyperparameter; the paper used `m = 10`.

**Prompt.** `P = (S, {m_{t-m}, …, m_{t-2}}, m_{t-1}, m_t)`.

**Extraction function.** An LLM-implemented `φ(P)` returns a set of salient memories
`Ω = {ω_1, …, ω_n}` — candidate facts for the knowledge base.

The critical nuance: facts are extracted **from the new exchange only**, while *remaining
aware* of the broader context. The summary and recent window are disambiguation aids — they
resolve pronouns, supply referents, disambiguate "there" and "then" — but they are not
extraction targets. Without this constraint every turn re-extracts the entire history.

**Asynchronous summary generation.** `S` is refreshed periodically by a module that runs
**independently of the main processing pipeline**, so extraction always receives a reasonably
fresh global view without paying summarisation latency inline. The consequence to design
around: `S` is *allowed to be stale*. The recent-message window is what covers the gap between
what the summary knows and the head of the conversation.

### 2.2 Update phase

For each candidate fact `ω_i ∈ Ω`, evaluated against existing memory to maintain consistency
and avoid redundancy:

1. Retrieve the **top `s` semantically similar** existing memories by vector similarity over
   dense embeddings. The paper used `s = 10`.
2. Present the candidate fact **plus those `s` memories** to the LLM through a function-calling
   interface the paper calls a **"tool call"**.
3. The LLM selects one of four operations.

**There is deliberately no separate classifier.** The paper is explicit: rather than training
or writing one, they leverage the LLM's reasoning about the semantic relationship between the
candidate and the retrieved memories, and let it choose directly.

| Operation | Condition | Effect |
|---|---|---|
| `ADD` | no semantically equivalent memory exists | create a new memory with a fresh unique id |
| `UPDATE` | the fact augments an existing memory with complementary information | replace that memory's content, **preserving its id** |
| `DELETE` | the fact contradicts an existing memory | remove the contradicted memory |
| `NOOP` | the fact is already present or irrelevant | nothing |

### 2.3 Algorithm 1, in full

Two details appear only in the appendix pseudocode and are easy to miss from the prose:

**The UPDATE guard.** The replacement is conditional on an information-content comparison —
the existing memory is replaced only when the new fact is *richer*:

```
if InformationContent(f) > InformationContent(m_i) then
    M ← (M \ {m_i}) ∪ {(id_i, f, "UPDATE")}     # id preserved
end if
```

If the candidate is not richer, the existing memory stands and nothing happens. So `UPDATE`
can be selected by the LLM and still be a no-op in practice.

**The classification order.** `ClassifyOperation` is specified as a cascade, and the ordering
matters — contradiction is checked *before* augmentation:

```
if ¬SemanticallySimilar(f, M)  → ADD       # new information not present
else if Contradicts(f, M)      → DELETE    # conflicts with existing memory
else if Augments(f, M)         → UPDATE    # enhances existing memory
else                           → NOOP      # no change required
```

Note the asymmetry with the prose description of `UPDATE`: the algorithm resolves both
`DELETE` and `UPDATE` against a *specific* memory (`FindContradictedMemory`,
`FindRelatedMemory`), so both operations target one of the `s` retrieved candidates, not the
store at large.

### 2.4 What the store looks like

Memories are **dense natural-language statements**, not chunks of transcript. This is the
source of both the accuracy advantage (less noise reaching the answering LLM) and the cost
advantage: roughly **7k tokens per full conversation**, against ~26k tokens for the raw
transcript. Compression, not archival.

Memory is **per-participant**: each speaker has their own namespace, and both namespaces are
supplied at answer time. Scoping is architectural, not an afterthought.

### 2.5 Answer generation

The base Bighead prompt instructs the answering model to:

- Analyse memories from **both speakers**.
- Pay special attention to **timestamps** in determining the answer.
- On contradictory memories, **prioritise the most recent**.
- **Convert relative time references into absolute dates** using the memory's own timestamp —
  a memory dated 4 May 2022 saying "went to India last year" means 2021 — and answer with the
  absolute date, discarding the relative phrase.
- Not confuse **character names mentioned inside memories** with the users who own them.

(The prompt also caps answers at 5–6 words, which is a benchmark artefact rather than an
architectural requirement.)

The dependency to notice: timestamps must be stored *and rendered into the prompt*, or the
relative-to-absolute conversion has nothing to anchor on.

---

## 3. Bighead^g — graph memory

### 3.1 Representation

A **directed labeled graph** `G = (V, E, L)`:

- **V — nodes = entities.** e.g. `Alice`, `San_Francisco`.
- **E — edges = relationships** between entities, e.g. `lives_in`.
- **L — labels = semantic types** on nodes, e.g. `Alice → Person`, `San_Francisco → City`.

Each entity node `v ∈ V` carries exactly three components:

1. **Entity type** — a classification (Person, Location, Event, …).
2. **Embedding vector `e_v`** — captures the entity's semantic meaning. This is what makes node
   resolution and entity-centric anchoring possible.
3. **Metadata**, including a **creation timestamp `t_v`**.

Relationships are **triplets `(v_s, r, v_d)`** — source node, labeled relation, destination
node. Edges also carry metadata; this is where validity and obsolescence markers live.

Note the asymmetry: nodes are embedded, and triplets are *separately* embedded as rendered
text for the semantic-triplet retrieval path (§3.4). Two distinct uses of embedding that
should not be conflated.

### 3.2 Extraction — a two-stage LLM pipeline

**Stage 1 — Entity extractor.** Processes the input text and identifies entities *with their
types*. Entities are "the key information elements in conversations", explicitly including
**people, locations, objects, concepts, events, and attributes**. The selection criteria the
extractor applies:

- **semantic importance**
- **uniqueness**
- **persistence**

That is, any discrete information that could matter for future reference or reasoning. The
paper's travel example lists destinations (cities, countries), transportation modes, dates,
activities, and participant preferences. Worth noting: *dates* and *preferences* are entities
here, not merely attributes on an edge — which is part of why the graph variant does well on
temporal questions.

**Stage 2 — Relationship generator.** Takes the extracted entities plus their conversational
context and derives the connections:

- For **each potential entity pair**, evaluate whether a meaningful relationship exists.
- If so, classify it with an appropriate label — examples given: `lives_in`, `prefers`,
  `owns`, `happened_on`.
- Reason over linguistic patterns, contextual cues and domain knowledge, capturing **both
  explicit statements and implicit information** in the dialogue.

Both stages use LLM **function calling**, which the paper credits as what makes structured
extraction from unstructured text reliable.

### 3.3 Storage and update — node resolution and conflict handling

For each **new relationship triple**:

1. Compute embeddings for **both** source and destination entities.
2. Search the existing graph for nodes with semantic similarity above a threshold `t`.
3. Depending on what was found:
   - neither exists → **create both nodes**,
   - one exists → **create only the missing one**,
   - both exist → **reuse the existing nodes**.
4. Establish the relationship edge between the resolved nodes, with appropriate metadata.

This embedding-threshold match **is** the entity resolution mechanism — how `SF`,
`San Francisco` and `San Fran` collapse onto one node instead of fragmenting the graph. `t` is
the critical tuning knob: too low merges distinct entities, too high fragments them.

**Conflict detection and resolution.** When new information arrives, a conflict detector
identifies existing relationships that potentially conflict with it. An **LLM-based update
resolver** then decides whether certain relationships should be considered obsolete.

The pivotal design point: obsolete relationships are **marked invalid, not physically
removed**. The graph is append-mostly. This retains the record of what was believed and when,
which is precisely what enables temporal reasoning — "where did she live *before* she moved?"
is answerable only if the superseded `lives_in` edge still exists, flagged as no longer valid.

This is a direct contrast with base Bighead's `DELETE`, which does remove. The graph variant
trades storage for a queryable history, and that trade is where its temporal advantage comes
from.

### 3.4 Retrieval — a dual strategy

Two complementary mechanisms run together, covering different query shapes.

**(a) Entity-centric retrieval** — for targeted, entity-focused questions.

1. Identify the key entities in the query.
2. Use semantic similarity to locate the corresponding **anchor nodes**.
3. From those anchors, systematically explore **both incoming and outgoing** relationships.
4. Construct a **subgraph** capturing the relevant contextual information.

Bidirectional traversal matters: facts about an entity live on edges pointing *at* it as often
as on edges pointing *from* it.

**(b) Semantic triplet retrieval** — for broader, conceptual queries.

1. Encode the **entire query** as a single dense embedding.
2. Match it against **textual encodings of every relationship triplet** — each triplet is
   rendered to text and embedded.
3. Compute fine-grained similarity between query and all triplets.
4. Return only those above a configurable **relevance threshold**, ranked by decreasing
   similarity.

Together these handle both "who is Alice's employer" (entity-centric) and "what does this
person care about" (semantic-triplet).

### 3.5 Answer generation

The Bighead^g prompt is the base prompt plus one extra instruction and two extra context
sections. Per participant:

```
Memories for user {id}:   {natural-language memories}     ← base Bighead
Relations for user {id}:  {graph triplets / subgraph}     ← Bighead^g
```

The added instruction: *"Analyze the knowledge graph relations to understand the user's
knowledge context."* Everything else — timestamps, recency preference on contradictions,
relative-to-absolute date conversion, don't-confuse-character-names — carries over unchanged
from §2.5.

### 3.6 Operational characteristics

- Footprint roughly **doubles** versus base Bighead (~14k vs ~7k tokens per conversation), from
  storing nodes and relationships alongside the natural-language memories.
- Graph construction completes **in under a minute** even worst-case. The paper contrasts this
  pointedly with systems whose graph construction runs as extended asynchronous background
  work and is not reliably queryable for hours — a memory you cannot read back immediately
  after writing is not usable in an interactive agent.
- Search latency is higher than base Bighead but still low in absolute terms; the graph's cost is
  moderate, not prohibitive.

---

## 4. Temporal reasoning, and why the two representations are complementary

The paper asserts that the graph helps temporal reasoning and that the two memory forms work
together, but does not explain the mechanism. This section works it out. Everything in §4.1 is
grounded in the paper's stated design; §4.3 onward is analysis extending it.

### 4.1 "Temporal" is three different clocks

Questions filed under temporal reasoning actually depend on three distinct notions of time,
and they are served by different parts of the system.

| Clock | Meaning | Example | Where it lives |
|---|---|---|---|
| **Utterance time** | when the statement was made | this memory was written 4 May 2022 | memory / node timestamp |
| **Event time** | when the described thing happened | the trip was in March 2023 | inside the fact; date-as-entity in the graph |
| **Validity time** | the span over which a fact was true | she lived in SF from Jan 22 to Jun 23 | edge validity interval |

Utterance time is what powers the prompt's relative-to-absolute conversion — "last year" is
meaningless without knowing when it was said. Event time is content. **Validity time is the one
base Bighead has no representation for at all**, and it is where the graph's advantage comes from.

### 4.2 Why base Bighead loses temporal information

Base Bighead's update phase resolves contradiction with `DELETE`. When "I moved to New York"
arrives and contradicts "User lives in San Francisco", the San Francisco memory is **removed
from the store**.

The resulting store is excellent at one thing: it holds a single, consistent, current snapshot.
"Where do I live?" retrieves exactly one memory with no chance of surfacing the stale one.

But "Where did I live before New York?" is now **unanswerable at any retrieval setting**. This
is not a ranking failure that a bigger `k` or a lower threshold could fix — the information no
longer exists. Deletion is what makes the current snapshot clean, and it is the same thing that
makes the history irrecoverable.

There is a second, subtler loss. Ordering questions — "did I join the gym before or after
starting the job?" — require the answering LLM to retrieve *both* memories and compare their
timestamps in the prompt. Under a single vector-similarity channel, whichever memory is
lexically closer to the query dominates, and the other may fall below the cut. Two-fact
comparison is fragile when both facts must independently win a similarity contest.

### 4.3 Three mechanisms by which the graph recovers it

**(a) Invalidation preserves the superseded fact.** The `lives_in SF` edge still exists, flagged
as no longer valid. "Before" questions have something to retrieve. This follows directly from
the paper's append-mostly policy and is the headline mechanism.

**(b) Supersession encodes ordering even without dates.** This is the non-obvious one. When edge
A is invalidated *by* edge B, the graph has recorded that A preceded B — even if neither carries
an explicit date and the conversation never stated when the change happened. The **sequence of
updates is itself temporal information**. Base Bighead generates exactly the same signal during its
update phase and then discards it: a `DELETE` knows that the removed memory came before the one
replacing it, and that knowledge is thrown away with the row.

**(c) Traversal retrieves a timeline exhaustively; similarity retrieves approximately.** For
"where did she live before", entity-centric retrieval anchors on the `Alice` node and follows
`lives_in` edges — returning *every* such edge with its validity interval, as a complete ordered
set. This is retrieval by **structure**, and structure is exhaustive. Vector search over
natural-language memories is retrieval by **resemblance**, and resemblance is approximate: each
memory must independently clear a similarity threshold for the same query string.

Additionally, because the paper treats **dates as entities**, a date becomes a node that many
events can anchor to. "What was going on in March 2023?" turns into a traversal from a date
node rather than a similarity search for a string.

### 4.4 A worked example

Conversation across three sessions:

```
Jan 2022  "I just moved to San Francisco for a job at Acme."
Mar 2023  "Work's been rough — Acme laid off half the team but I survived."
Jun 2023  "I'm leaving SF, moving to New York. Got an offer from Belltown."
```

**Base Bighead store afterwards** (contradictions deleted):

```
"User lives in New York"                                    (Jun 2023)
"User works at Belltown"                                    (Jun 2023)
"Acme laid off half the team; user survived"                (Mar 2023)
```

The SF and Acme employment memories are gone — they were contradicted.

**Graph afterwards** (contradictions invalidated):

```
Alice -lives_in->  SF         [Jan 22 – Jun 23, superseded by →NYC]
Alice -lives_in->  NYC        [Jun 23 –        ]
Alice -works_at->  Acme       [Jan 22 – Jun 23, superseded by →Belltown]
Alice -works_at->  Belltown   [Jun 23 –        ]
Acme  -had_event-> layoff     -happened_on-> Mar 2023
```

Now run four questions through both:

| Question | Base Bighead | Graph |
|---|---|---|
| "Where do I live?" | **wins** — one memory, unambiguous, cheap | works, but must filter on validity |
| "Where did I live before New York?" | **cannot answer** — fact deleted | **wins** — the edge with `valid_to = Jun 23` |
| "Why did I leave SF?" | **wins** — motivation lives in a rich sentence | **fails** — no triplet frame holds "why" |
| "Was I at Acme when the layoffs happened?" | partial | partial |

That last row is the important one. The graph supplies the **temporal frame**: Acme employment
spans Jan 22 – Jun 23, the layoff is anchored at Mar 2023, and interval containment gives *yes,
she was there*. But the graph cannot tell you she **survived** it — `works_at` carries no such
qualification. That detail exists only in the natural-language memory.

> The graph tells you **when things were true**. The natural language tells you **what they
> meant**.

Neither answers the question alone. This is why the paper's answer prompt supplies both
sections, and why they are not two encodings of the same information.

### 4.5 What the graph gives up

The complementarity runs both ways, and the graph's losses are systematic rather than
incidental:

1. **A triplet is a lossy projection.** "I'm vegetarian, but I'll eat fish when travelling in
   Japan" has no faithful `(subject, predicate, object)` form. `user -prefers-> vegetarian`
   drops the exception, and the exception is the useful part. Qualification, hedging,
   conditionality, causation, and degree all live outside the triplet frame. Natural language
   holds them for free because it does not project at all.
2. **Extraction fragility compounds multiplicatively.** The graph path needs entity extraction
   to succeed **and** relation generation to succeed **and** node resolution to land on the
   right side of threshold `t`. Three independent chances to fail per fact. Natural-language
   extraction is one step, and a slightly imperfect sentence is still useful — whereas a
   wrongly-merged node is *actively harmful*, because it fabricates relationships that were
   never stated.
3. **It fragments what needs to be read whole.** This is the most plausible explanation for the
   paper's own surprising result that the graph does not help multi-hop questions. Multi-hop in
   conversation usually is not graph-traversal-shaped — "why did she quit?" means synthesising
   motivation expressed across several rich statements, not walking a path between entities.
   Shattering those statements into triplets destroys exactly the connective tissue the question
   needs. *(The paper reports this result and speculates about "overhead or redundancy" without
   explaining it; this reading is inference.)*

### 4.6 The retrieval argument

The deepest reason to run both is not representational, it is about **retrieval failure modes**.

- Natural-language memory is retrieved by **embedding similarity** — it misses when the query is
  phrased unlike the stored fact.
- Entity-centric graph retrieval is anchored by **entity match, then structural traversal** — it
  misses when entity extraction or resolution fails, *not* when phrasing diverges.

These failure modes are **largely uncorrelated**. A query whose phrasing diverges from the
stored sentence can still hit via its entity anchor; a fact whose entities were mis-resolved can
still be found by similarity. Two channels with independent failure modes recover more than
either channel alone at the same total budget — the standard hybrid-retrieval argument, applied
here across two different *representations* rather than two scoring functions over one index.

This is also why the paper's third channel (semantic triplet search) exists: it is a
similarity-based path over graph content, deliberately covering the case where entity-centric
anchoring fails but the triplet still resembles the query.

### 4.7 Implementation consequences

1. **Do not unify the two removal semantics.** Base deletes; the graph invalidates. The
   asymmetry *is* the temporal advantage. Making base Bighead soft-delete would be a reasonable
   independent improvement, but do not make the graph hard-delete.
2. **Prefer an interval to a boolean.** `valid_from` / `valid_to` / `superseded_by` answers
   "before", "during", and "as of"; an `is_valid` flag answers only "now".
3. **Record supersession links, not just invalidity.** Mechanism (b) depends on knowing *which*
   edge replaced which — that pointer is the dateless ordering signal.
4. **Retrieval must distinguish "retrievable" from "current".** Invalid edges have to be
   reachable for "before" questions, yet must never be presented to the answering LLM as present
   fact. Render the interval into the prompt rather than filtering invalid edges out entirely.
5. **Keep all three clocks distinct in the schema.** Collapsing utterance time and event time
   into one `inserted_at` breaks the relative-to-absolute conversion that the answer prompt
   depends on.
6. **Let the channels fail independently.** Since the argument for running both rests on
   uncorrelated failure modes, a graph-extraction error must not abort base ingestion, and a
   traversal miss must not suppress vector results.


---

## 5. Design principles worth carrying into an implementation

1. **Incremental, not batch.** Everything is driven per message pair, in both pipelines. Newly
   added memories are immediately usable.
2. **The LLM is the decision-maker, not just an extractor.** Operation selection (base) and
   obsolescence resolution (graph) are LLM judgements exposed through function calling, not
   hand-written rules or a trained classifier.
3. **Compress, don't archive.** Store salient facts, not raw chunks. This produces both the
   accuracy gain (less noise reaching the LLM) and the cost gain. The paper explicitly
   criticises caching a full abstractive summary at every node *while also* storing facts on
   edges — massive redundancy for no benefit.
4. **Two different removal semantics, deliberately.** Base Bighead deletes; the graph invalidates
   and keeps. Don't unify them — the difference is the source of the graph's temporal
   advantage.
5. **Two embedding roles.** Node embeddings serve entity resolution and query anchoring;
   triplet-text embeddings serve holistic query matching. Separate concerns.
6. **Timestamps everywhere.** Node creation time and memory timestamps are load-bearing for
   the relative-to-absolute date conversion at answer time, and for recency-wins conflict
   handling.
7. **Stale global context is acceptable; missing recent context is not.** The async summary
   plus recent-message window is a deliberate latency/freshness trade.
8. **The graph is an additional channel, not a replacement.** It roughly doubles footprint and
   adds latency, helps temporal and open-domain, and does nothing for single-hop or multi-hop.
   Layer it on the base store.

---

## 6. Parameters the paper names

| Symbol | Meaning | Paper's value |
|---|---|---|
| `m` | recent-message window fed to extraction | 10 |
| `s` | similar memories retrieved for the update decision | 10 |
| `t` | node-similarity threshold for entity resolution | unspecified ("a defined threshold") |
| — | relevance threshold for semantic triplet retrieval | unspecified ("configurable") |
| — | summary refresh cadence | unspecified ("periodically") |
| — | subgraph traversal depth | unspecified |

---

## 7. Underspecified areas

This is a systems paper; several mechanics are described at the level of intent only. These
are the decisions left to the implementer.

### 6.1 Base Bighead

- **How `S` is generated and refreshed.** "Periodically" — on a timer, every N messages, or on
  a staleness measure. Also whether it is regenerated from the full history each time or
  updated incrementally.
- **What `InformationContent` actually measures.** Algorithm 1's UPDATE guard depends on it and
  the paper never defines it. Token count, proposition count, and an LLM judgement are all
  plausible and behave differently.
- **The similarity threshold for `SemanticallySimilar`.** The `ADD` branch turns on it, and no
  value or method is given — it may be implicit in the top-`s` retrieval rather than an
  explicit cutoff.
- **Batch interactions between candidate facts.** `Ω` can hold several facts from one pair. If
  two of them target the same existing memory, or one ADDs something a later one would UPDATE,
  the paper's per-fact loop has no coordination.
- **Whether `DELETE` is soft.** The algorithm shows `M ← M \ {m_i}`, i.e. hard removal, which
  leaves no audit trail and no way to explain a change to a user.
- **Provenance.** Nothing is said about linking a memory back to the messages that produced it.
- **Concurrency.** Two message pairs ingesting simultaneously for one scope will race on the
  same retrieved candidates.

### 6.2 Bighead^g

- **Conflict detection scope.** *How* candidate conflicting edges are found before the LLM
  resolver judges them. The natural reading is edges sharing a source node and relation label,
  but the paper does not say.
- **Which relations are single-valued.** `lives_in` should supersede; `visited` should
  accumulate. Nothing distinguishes them — this needs to be either a relation-type policy or
  part of the resolver's prompt.
- **The invalidation representation.** "Marked as invalid" — a boolean, a
  `valid_from`/`valid_to` interval, or a supersession pointer. The interval is richer and
  matches the stated temporal-reasoning goal.
- **Node type conflicts.** What happens when the same resolved node is assigned different types
  by different extractions.
- **Traversal depth** for entity-centric retrieval — 1-hop versus n-hop is not stated.
- **Whether invalid edges are excluded from retrieval.** They must be *retrievable* for
  temporal questions but should presumably not be presented as current fact. The paper doesn't
  address the distinction.
- **How the two graph channels merge** with each other and with base memories before reaching
  the answering LLM. No ranking or de-duplication scheme is given.
- **Whether graph extraction reuses the same context `P`.** The paper says the extractor
  "processes the input text" without specifying. Using the same contextualised prompt is the
  consistent choice, since resolving pronouns and implicit facts requires it.
- **Triplet-embedding maintenance.** Every triplet is embedded for channel (b); nothing is said
  about reindexing when nodes merge or edges are invalidated.

---

## 8. Minimal mental model

```
ingest(message_pair):
    S      ← current conversation summary          (refreshed asynchronously)
    recent ← last m messages
    P      ← (S, recent, m_{t-1}, m_t)

    ── base channel ────────────────────────────────────────────────
    facts ← LLM_extract(P)                          # from the new pair only
    for f in facts:
        candidates ← vector_top_s(f)                # s = 10
        verdict    ← LLM_tool_call(f, candidates)   # ADD|UPDATE|DELETE|NOOP
        case verdict:
            ADD    → insert(new_id, f)
            UPDATE → if info(f) > info(m_i): replace(m_i.id, f)   # id preserved
            DELETE → remove(m_i)
            NOOP   → ()

    ── graph channel ───────────────────────────────────────────────
    entities ← LLM_entity_extract(P)                # (name, type)
    triplets ← LLM_relation_generate(entities, P)   # (src, rel, dst)
    for (s, r, d) in triplets:
        s_node ← resolve_or_create(s, threshold=t)  # by node embedding
        d_node ← resolve_or_create(d, threshold=t)
        for c in detect_conflicts(s_node, r, d_node):
            if LLM_resolver(c, new=(s,r,d)) == OBSOLETE:
                mark_invalid(c)                     # never hard-delete
        create_edge(s_node, r, d_node, metadata)
        index_triplet_embedding(render_text(s, r, d))

search(query):
    memories ← vector_search(query)                        # base
    anchors  ← resolve_query_entities(query)
    subgraph ← traverse(anchors, incoming + outgoing)      # graph channel (a)
    triplets ← triplet_embedding_search(query, threshold)  # graph channel (b)
    return merge(memories, subgraph, triplets)

answer(question, recall):
    prompt ← "Memories for user X: …\nRelations for user X: …\n…"
    # timestamps visible · recency wins on contradiction
    # relative dates converted to absolute against memory timestamps
```

---

## 9. Future directions the paper flags

- Reducing graph-operation latency — the graph variant's main cost.
- **Hierarchical** memory architectures blending efficiency with relational representation.
- Richer **consolidation** mechanisms inspired by human cognition.
- Extension beyond conversation — procedural reasoning, multimodal interaction.
