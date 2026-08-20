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
