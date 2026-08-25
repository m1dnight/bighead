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
3. **One memory channel, not two.** The paper's `Mem0^g` graph channel is dropped — see
   [attic/graph-channel.md](attic/graph-channel.md) for the design and why. Temporal reasoning lives
   on memories themselves (event intervals, supersession) rather than on graph edges, which is the
   direction upstream mem0 itself took.
4. **Surfaces last.** REST, MCP and the Claude Code hooks are thin wrappers over a
   `Mem0` boundary module. They are cheap once the boundary is right and worthless before.

## Phases

| # | Phase | Delivers | Plan |
|---|-------|----------|------|
| 1 | Scaffolding | Tooling, pgvector dev DB, CI, Dockerfile | [01-scaffolding.md](01-scaffolding.md) |
| 2 | Domain data | Core structs and their invariants — no persistence | [02-domain-data.md](02-domain-data.md) |
| 3 | Ports | LLM + embedder behaviours, config from env, stub and real adapters | [03-ports.md](03-ports.md) |
| 4 | Hook ingress | A Claude Code session posts its transcript; mem0 normalises it to `Message`s | [04-hook-ingress.md](04-hook-ingress.md) |
| 5 | Fact extraction | `Message`s in, candidate `Fact`s out, in one LLM call — not wired to anything | [05-fact-extraction.md](05-fact-extraction.md) |
| 6 | Message storage | The `messages` table and its store — `Message`s in, the same `Message`s out | [06-message-storage.md](06-message-storage.md) |
| 7 | Summaries | The running summary `S` — regenerated from the run's stored messages, wired to nothing | [07-summaries.md](07-summaries.md) |
| 8 | Summary wiring | The `Stop` pulse — `S` regenerated when stale, off the request path; nothing reads it yet | [08-summary-wiring.md](08-summary-wiring.md) |
| 9 | Extraction context | φ(P) — extraction reads `P = (S, recent, new)` assembled from the stores; still wired to no trigger | [09-extraction-context.md](09-extraction-context.md) |


Phases 1–3 are infrastructure and can be done back to back. Phase 4 is the first phase that
produces something demonstrable. Phases 6–7 are the reason this project exists; everything before
them is the substrate they need.

## Decisions already made

These are settled and should not be relitigated per-phase:

- **Postgres + pgvector, and no second datastore.** Vector search and every filter the system needs
  are covered by Postgres, and one store is what keeps a write atomic.
- **Memories are append-mostly.** Validity intervals and supersession, never a hard delete. This is
  a deliberate upgrade over the paper's `DELETE`, which removes the row and with it both the audit
  trail and the ordering signal: a superseded memory knows it came before the one replacing it.
- **LLM-derived labels are strings, never atoms.** Anything that comes back from a model and gets
  stored stays a binary. Interning would grow the atom table without bound; it is never GC'd.
- **`MemoryOperation` is the purity pivot.** The core decides *what* to do and returns
  `{:add, Fact.t()} | {:update, id, Fact.t()} | {:delete, id} | :noop`. The boundary performs it.
  Every decision rule is therefore testable without a database. *(Phase 2 refines this: the core
  returns a `Decision` wrapping that operation with the reason it was chosen — the pivot is the
  operation, but the reason cannot be reconstructed after the fact.)*
- **The core trusts its input; the boundary validates.** One validation point, at the public API.
