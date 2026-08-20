# Mem0 in Elixir — Implementation Plan

An Elixir implementation of Mem0 and Mem0^g (see [mem0-paper-notes.md](../docs/mem0-paper-notes.md)),
exposed to coding agents such as Claude Code.

## Sequencing principle

The layering follows DFTBLW — **D**ata, **F**unctional core, **T**ests, **B**oundaries,
**L**ifecycles, **W**orkers. Concretely that dictates the phase order:

1. **Data before behaviour.** The structs and tables come first, because under immutability the
   wrong shape produces compensating code everywhere downstream.
2. **Ports before pipelines.** The LLM and embedder behaviours land in Phase 3 so that phases 4–7
   are testable with stub adapters and no network. Without this, every later phase drags a live
   API dependency into its test suite.
3. **Base Mem0 fully working before the graph.** The graph is not an alternative write path — it
   is a second one that runs alongside. Building it on an unproven base doubles the surface under
   debug. The paper's own results back this ordering: base Mem0 wins single-hop and multi-hop; the
   graph only adds temporal and open-domain.
4. **Surfaces last.** REST, MCP and the Claude Code hooks are thin wrappers over a
   `Mem0` boundary module. They are cheap once the boundary is right and worthless before.

## Phases

| # | Phase | Delivers | Plan |
|---|-------|----------|------|
| 1 | Scaffolding | Tooling, pgvector dev DB, CI, Dockerfile | [01-scaffolding.md](01-scaffolding.md) |
| 2 | Domain data | Core structs and their invariants — no persistence | [02-domain-data.md](02-domain-data.md) |
| 3 | Ports & adapters | LLM / Embedder / Clock behaviours + stubs | _not written yet_ |
| 4 | Ingestion | Extraction Φ + the ADD/UPDATE/DELETE/NOOP update phase | _not written yet_ |
| 5 | Retrieval | Hybrid semantic + lexical + entity recall over the NL store | _not written yet_ |
| 6 | Graph memory | Entity/relation extraction, node resolution, invalidation | _not written yet_ |
| 7 | Graph retrieval | Entity-centric traversal, triplet search, fusion | _not written yet_ |
| 8 | Surfaces | `Mem0` API, REST, MCP, Claude Code hooks, inspector | _not written yet_ |

Phases 1–3 are infrastructure and can be done back to back. Phase 4 is the first phase that
produces something demonstrable. Phases 6–7 are the reason this project exists; everything before
them is the substrate they need.

## Decisions already made

These are settled and should not be relitigated per-phase:

- **Postgres + pgvector, not Neo4j.** All three graph access patterns the paper needs — entity
  resolution (vector nearest-neighbour), semantic triplet retrieval (vector query), entity-centric
  retrieval (1–2 hops from an anchor) — are covered by Postgres. A second datastore would buy
  traversal depth we have no evidence we need, and cost us the single transaction that keeps the
  NL store and the graph consistent with each other.
- **Relations are append-only.** `valid_from` / `valid_to` / `superseded_by`, never a hard delete.
  This is a deliberate upgrade over the paper's boolean invalidation flag: it is what makes
  interval-containment questions ("was I at Acme when the layoffs happened?") answerable.
- **LLM-derived labels are strings, never atoms.** Entity `type` and relation `label` come from
  model output. Interning them would grow the atom table without bound; it is never GC'd.
- **`MemoryOperation` is the purity pivot.** The core decides *what* to do and returns
  `{:add, Fact.t()} | {:update, id, Fact.t()} | {:delete, id} | :noop`. The boundary performs it.
  Every decision rule is therefore testable without a database. *(Phase 2 refines this: the core
  returns a `Decision` wrapping that operation with the reason it was chosen — the pivot is the
  operation, but the reason cannot be reconstructed after the fact.)*
- **The core trusts its input; the boundary validates.** One validation point, at the public API.

## Open questions carried across phases

Each is owned by the phase that first cannot proceed without it.

| Question | Owner | Notes |
|---|---|---|
| Embedding model and dimension | Phase 3 | Blocks the `vector(N)` column type and index choice in whichever phase owns persistence. **pgvector's HNSW/IVFFlat indexes cap at 2000 dimensions for `vector`** — a 3072-dim model needs `halfvec`. Pick before writing the memories migration. |
| Which phase owns persistence — schemas, migrations, the store boundary | Phase 3 | Phase 2 is structs only. The natural home is Phase 4, where the boundary performs what the core decides, but that makes Phase 4 large. Decide before Phase 3 defines the ports. |
| Async execution strategy — `Task` or Oban | Phase 4 | The W in DFTBLW has no owner phase yet, but the paper requires an asynchronously-refreshed summary and a Claude Code hook must return fast. If Oban, its migration has to be ordered against the persistence phase's schemas, and it brings a supervision-tree entry and `testing: :manual`. |
| Hook transport — HTTP to a local server, or a stdio MCP binary | Phase 8 | Determines whether the Phase 1 release image is even the right artifact. A local coding agent wants a fast-starting process, not a container serving HTTP — unless the hook is an HTTP client to a locally-running server. |
| Postgres major, and whether to pin pgvector by digest | Phase 1 | `pgvector/pgvector:pg18` pins the Postgres major only; the tag is rebuilt. Choose the major from the deployment target, since `CREATE EXTENSION` needs superuser on most managed offerings. |
| LLM request/response redaction policy | Phase 1 | Memory contents are user data and prompts are what you most want to log. Decide before debug logging spreads across four phases. |
| LLM provider and structured-output mechanism | Phase 3 | The paper's four-way operation choice is function calling; the modern equivalent is a strict tool schema or `output_config.format`. |
| Similarity threshold `t` for node resolution | Phase 6 | The paper leaves it unspecified. Needs a fixture corpus to tune against. |
| Summary refresh cadence | Phase 4 | Paper says "asynchronously refreshed", no interval. |
| Traversal depth for entity-centric retrieval | Phase 7 | Start at 1, measure before going to 2. |
| Whether within-session extraction is worth it at all | Phase 8 | For Claude Code specifically, the session transcript is already in context — memory only buys you *crossing* sessions. |
