# Phase 8 — Summary wiring

**Goal:** the trigger Phase 7 deliberately withheld. One boundary function — check whether a run's
`S` has fallen behind its stored messages, regenerate and store it if so, do nothing otherwise —
pulsed once per turn from the `Stop` hook, off the request path. After this phase a live session
grows a summary as a side effect of existing, and every item [§7.4](07-summaries.md) bequeathed is
either resolved here or re-parked with a number attached. Nothing *reads* `S` yet; that stays with
the `Prompt` phase.

The shape is the one the design discussion imagined — *if `summary(scope)` is outdated, then
generate* — and it survives contact intact. The work of this phase is deciding where each clause
of that sentence lives: the *outdated* decision in the core, the *then generate* composition in
the boundary, and the *if* — when anybody bothers to ask — in the callers. `refresh(scope)` is
check-then-act and idempotent: calling it twice is two indexed reads and a no-op, so cadence is a
policy its callers own rather than something baked into the function. Today the caller is the
`Stop` pulse; a sweeper, a recall-time catch-up, or a hand-driven IEx session are all the same
call later.

**The settlement problem.** The server never learns that a turn's backfill is complete.
`stop.py` calls `lines-seen`, then POSTs chunks to `backfill` in a sequential loop — each chunk is
stored before the response is sent, so each iteration returns only after its rows landed — and
then exits. The route it now pulses, `/hooks/stop`, answers 200 and does nothing — its `@doc`
has been reserving it for summaries since the Phase 6 backfill work. The signal the server
lacks, the sender has for free: its loop returning *is* "stored through head". As of `a176c36`
the sender says so — one final `POST /hooks/stop` after the loop (§8.4) — rather than have the
server guess.
The alternatives all lose on the same facts. Triggering per backfill chunk fires mid-settlement:
a first backfill of a long session would regenerate over partial history several times in one
turn, each summary superseded seconds later. `UserPromptSubmit` blocks the user's session (fact
worth repeating: that route must never be why a turn stalls) and sees a history that is one turn
behind. A timer sweeper is a process bought to approximate a signal the sender sends for free —
plus a stale-scopes SQL query that duplicates core policy into the store, spent mostly on dead
runs nobody will read.

**Periodic without a clock.** The `Stop` hook fires every turn, and the staleness check throttles
the spend: most pulses are two indexed reads and an immediate `:fresh`. Under regeneration the
cadence knob *is* the cost knob (§7.4), and it lives in one core constant — `max_lag` — not in a
schedule.

## The whole pipeline

```
stop.py: backfill loop returns (history settled)
   │  POST /hooks/stop  (the Stop payload, verbatim)
   ▼
HooksController.stop/2 ─ Ingest.scope/2 ─▶ Summarize.refresh_async/1 ─▶ 200, inert, immediately
                                                  │ Task.Supervisor.start_child
                                                  ▼
                        Summarize.refresh/2   (the API: synchronous, what tests and IEx call)
                            Summaries.latest/1 ─▶ S | nil ─▶ Messages.count_since/2 ─▶ pending
                                                                      │
                                                     Core.Summary.stale?/2  (pure policy)
                                        false ─▶ :fresh — two indexed reads, no LLM
                                        true ──▶ for_run/1 ─▶ regenerate/2 ─▶ put/1
```

One new supervision child, zero new modules. The composition goes in `Bighead.Summarize` because that
module already owns the summary's impure step; a new module would be surface for one function, and
putting it in `Bighead.Summaries` would fatten a deliberately thin store. Policy goes in
`Bighead.Core.Summary` because that is where policy stays testable without a pipeline.

---

## 8.1 `Bighead.Core.Summary.stale?/2` — rewritten, because its unit was the bug

`stale?/3` is rewritten, not wrapped. The add-a-new-function rule exists to protect callers, and
`stale?/3` has none — Phase 7 says so in as many words — so preserving its arithmetic behind a
wrapper would be compatibility theater around a defect. And the arithmetic is a defect, not a
tuning problem: `head_seq - through_seq` subtracts transcript *line* positions, `seq` is not
dense in stored messages (the normalizer drops most lines), and no constant fixes a
session-shape-dependent ratio. A tool-heavy turn burns a hundred lines on entries that never
become messages — the lag inflates while nothing `S` reads has changed — and a dense
conversational session runs near one line per message, where a line budget big enough for the
tool-heavy case quietly tolerates a lag of that many *messages*. The invariant the whole design
leans on — "a lagging `S` is survivable because the recent window covers its gap" — is
denominated in messages: extraction's window is its newest **20 stored messages**
(`Extraction.@max_messages`). Line units break that invariant exactly when the session is
densest, which is when `S` matters most.

So the policy counts what `S` actually summarizes — stored messages — and collapses to one
comparison over the right unit:

```elixir
@typedoc "How many stored messages `S` may fall behind the head before it needs redoing."
@type max_lag :: non_neg_integer()

# Unchanged in value, and now meaning what it always said.
@default_max_lag 10

@doc """
Whether `pending` — how many stored messages arrived after the last one the
summary read — has outgrown `max_lag`. Takes the count rather than reading
the store, for the reason the old version took a head seq rather than a
clock: the refresh policy stays testable without a running pipeline.
"""
@spec stale?(non_neg_integer(), max_lag()) :: boolean()
def stale?(pending, max_lag \\ @default_max_lag)
    when is_integer(pending) and is_integer(max_lag),
    do: pending > max_lag
```

- **The `nil`-summary case leaves the core entirely.** "Never summarized" is just "every stored
  message is pending", which the boundary expresses by counting from seq −1 — so a young run
  still gets no summary until it has more than `max_lag` messages: the recent window *is* the
  whole conversation there, and a summary of it is pure token spend — the same argument that
  makes a lagging `S` survivable ("stale global context is acceptable; missing recent context is
  not") applied at birth. An empty run is `pending = 0`, never stale, no special case anywhere.
- **The summary struct drops out of the signature.** The policy needs nothing from it — the
  boundary already extracted `through_seq` to compute `pending` — and a policy that takes
  measured inputs is the module's own established shape.
- No clock, no store, same layering test. `needs_refresh?/3`, the wrapper an earlier draft of
  this plan proposed, is never born.

## 8.2 `Bighead.Summarize.refresh/2` — the synchronous composition

`regenerate/2` stays exactly as it is. Beside it, the whole freshness pipeline in one named
function — the API of this phase, the thing tests and IEx call:

```elixir
@spec refresh(Scope.t(), keyword()) :: :fresh | {:ok, Summary.t()} | {:error, term()}
def refresh(%Scope{} = scope, opts \\ []) do
  through_seq = scope |> Summaries.latest() |> through_seq()

  scope
  |> Messages.count_since(through_seq)
  |> Summary.stale?()
  |> maybe_regenerate(scope, opts)
end

# A missing summary has read nothing: it is a summary through seq −1, one
# before the first line a message can occupy.
defp through_seq(nil), do: -1
defp through_seq(%Summary{through_seq: seq}), do: seq

defp maybe_regenerate(false = _stale, _scope, _opts), do: :fresh

defp maybe_regenerate(true = _stale, scope, opts) do
  with {:ok, summary} <- scope |> Messages.for_run() |> regenerate(opts),
       :ok <- Summaries.put(summary) do
    {:ok, summary}
  end
end
```

`Bighead.Messages` grows one read beside `for_run/1`, with the same exact-scope match:

```elixir
@doc """
How many of this run's stored messages sit after `seq`. With −1, the whole
run. Recomputed on every ask and never stored, so a backfill that rewrites
history corrects the answer instead of drifting from it.
"""
@spec count_since(Scope.t(), integer()) :: non_neg_integer()
def count_since(%Scope{} = scope, seq) when is_integer(seq) do
  scope |> for_scope() |> where([row], row.seq > ^seq) |> Repo.aggregate(:count)
end
```

- **The check is cheap by construction.** Two indexed reads decide — `latest/1`, then
  `count_since/2` riding the existing `[user_id, app_id, run_id, seq]` index as a range scan —
  and the full transcript is read only after the policy already said regenerate.
  `lines_seen/1` appears nowhere in this path: it stays what it always was, backfill's cursor,
  and §7.4's off-by-one dissolves instead of needing the `- 1` an earlier draft carried.
- **Return contract.** `:fresh` — nothing to do: the run is empty, too young, or within
  `max_lag`, all the same `pending <= max_lag` with no separate cases. `{:ok, summary}` —
  regenerated *and* stored; the struct is what `latest/1` now reports. `{:error, term}` — LLM
  transport, `:malformed_summary`, or a store exception from `put/1`; in every error the previous
  row simply stays latest, which is the survivability `Core.Summary`'s own docs already argue.
- **Deliberately no lock around the check-then-generate window.** The store is append-only and
  `latest/1` picks max `(through_seq, id)`, so a concurrent duplicate costs tokens, never
  correctness — and the trigger topology (one sequential sender per run, one pulse per turn)
  barely opens the window. A message landing *between* check and read only makes the regeneration
  cover more history, and `through_seq` is computed from the messages actually read, so the
  watermark stays honest. If a lock is ever wanted, it is a Registry keyed by scope around this
  same function; documented as the escape hatch, not built.
- `opts` passes through to the LLM call untouched. `max_lag` is *not* an option here: it is a
  core constant, and changing it should stay a visible edit to the core (its own comment says so).

## 8.3 `refresh_async/2` — off the request path

The LLM call takes seconds; the hook's HTTP request must not sit behind it. Holding the request
open instead (fully synchronous, zero new processes) was seriously considered and loses on three
couplings, all to client timeout behavior: the script's 5s timeout would need a carve-out an
order of magnitude larger for this one route, a client disconnect kills the request process
mid-regeneration and wastes the tokens spent so far, and Claude Code's own per-hook timeout sits
above both. One supervised Task removes all three for the price of one infrastructure child.

```elixir
@task_supervisor Bighead.Summarize.TaskSupervisor

@spec refresh_async(Scope.t(), keyword()) :: :ok
def refresh_async(%Scope{} = scope, opts \\ []) do
  {:ok, _pid} =
    Task.Supervisor.start_child(@task_supervisor, fn -> measured_refresh(scope, opts) end)

  :ok
end

defp measured_refresh(scope, opts) do
  {notify_pid, opts} = Keyword.pop(opts, :notify_pid)
  {duration, result} = :timer.tc(__MODULE__, :refresh, [scope, opts])

  :telemetry.execute(
    [:bighead, :summarize, :refresh],
    %{duration: duration},
    %{outcome: outcome(result), user_id: scope.user_id, app_id: scope.app_id, run_id: scope.run_id}
  )

  if notify_pid, do: send(notify_pid, {:refreshed, scope, result})
end

defp outcome(:fresh), do: :fresh
defp outcome({:ok, %Summary{}}), do: :regenerated
defp outcome({:error, _reason}), do: :error
```

- **All logic stays in the synchronous `refresh/2`**; the async wrapper is a few lines of
  supervision, measurement and notification, which is exactly how much untestable surface it
  should have.
- **`{Task.Supervisor, name: Bighead.Summarize.TaskSupervisor}`** goes in `application.ex` after the
  Repo and before the Endpoint. Tasks are `:temporary` (the default): restarting a failed LLM
  call helps nobody, and the next turn's pulse is the retry.
- **`start_child` is itself a synchronous call** to the supervisor — the back-pressure warning
  against `cast` does not apply, and concurrency across runs is bounded in practice by one pulse
  per turn per session. No pool until measurement says otherwise.
- **Telemetry is load-bearing, not optional.** For a fire-and-forget path it is the only failure
  surface. Counts, durations and identifiers only — the same redaction rule the ingest telemetry
  follows; the summary text never appears. `put/1` already passes `log: false`, and the refresh
  path adds no logging of its own, so no new place for content to leak appears — the canary
  check in the exit criteria is what proves it.
- **`:notify_pid` is the test seam** — the task sends `{:refreshed, scope, result}` so boundary
  tests `assert_receive` instead of sleeping. It rides in `opts` and is popped before the LLM
  ever sees the keyword list.

## 8.4 The pulse — already sent; one real line left in the controller

The sender half shipped as `a176c36`: after the backfill loop, `stop.py` POSTs the Stop payload
**verbatim** to `/hooks/stop`, with the ordering argument in its comment — sent after backfill
so that by the time the server acts on it, the turn's messages are already stored.

```python
# scripts/hooks/stop.py — main(), as committed:
for index in range(seen, len(entries), CHUNK_LINES):
    send(payload, entries, index)

# The Stop event itself, verbatim. Sent after backfill so that by the time
# the server acts on it — checking whether the summary needs updating — the
# messages of this turn are already stored.
post("/hooks/stop", payload)
```

Verbatim rather than a curated `{session_id, cwd}` body, and the choice costs nothing the config
did not already pay: `Ingest.scope/2` reads the keys it needs and ignores the rest, and
`last_assistant_message` riding along was priced in before this phase existed —
`config/config.exs` filters exactly that key because it is "the answer that rides along on
`Stop`", with dev deliberately unfiltered for reading payloads on purpose. It also keeps
`hook_event_name` in the body should the route ever emit the tagged telemetry ingest does. The
pulse keeps the script's 5s timeout — the server answers before any LLM work starts — and the
existing always-exit-0 posture already makes a lost pulse harmless: the summary stays stale one
turn and the next pulse catches it.

One bound on "the full conversation": `await_flush` waits up to 2s for the turn's final
assistant entry to reach the transcript file. When it misses, backfill — and therefore the
summary — runs one entry short and the pulse still fires; the next turn carries the entry, and
for a session's *last* turn it is the same accepted gap Phase 7 documented. The pulse states
"settled as of what was sent", not "complete forever".

What remains is the server half. The route contract is unchanged: 200 unconditionally, inert
body. The scope is derived by `Ingest.scope/2` — public precisely so that a sender asking about
its run and a backfill writing it cannot derive the address two different ways.

```elixir
@spec stop(Plug.Conn.t(), map()) :: Plug.Conn.t()
def stop(conn, params) do
  params
  |> Ingest.scope(Ingest.default_user_id())
  |> Summarize.refresh_async()

  json(conn, HookResponse.stop())
end
```

## 8.5 Settling §7.4 — dissolved rather than tuned

Phase 7 measured the drift and parked it; a wired trigger has to decide, because the constant now
multiplies real tokens. The resolution: fix the arithmetic to match the doc, not the doc to match
the arithmetic.

- **`max_lag` counts stored messages — what the typedoc claimed all along.** The rejected
  alternative was this plan's own first draft: keep the line-position subtraction and retune
  10 → 130 through §7.4's machine-local ratio (703 lines : 54 messages, ~13:1). Rejected because
  the ratio is a property of session *shape*, not of the system — §7.4 itself calls it
  "reproducible nowhere else" — and a constant tuned to it fails in both directions at once,
  over-firing on tool-heavy turns and under-covering dense ones past the 20-message window
  (§8.1). `@default_max_lag` stays 10, now in its intended unit; the price is one indexed count
  query where two integers used to subtract, which §8.2 shows costs nothing the check was not
  already paying.
- **The off-by-one is not fixed but mooted.** `lines_seen/1` returns a count, one past the head
  — and it no longer participates: the refresh path never computes a head position at all,
  only how many messages sit past the summary's watermark.
- **10 is still a placeholder.** A visible core edit, as its comment demands, and the
  duration/outcome telemetry this phase adds is the instrument for retuning it against real
  sessions: the `:fresh`/`:regenerated` ratio per turn is exactly the cadence-versus-cost curve.
- **The freshness SLA is currently anchored to nothing.** Recall still returns `""`; the first
  real reader of `S` arrives with `Prompt`/φ(P). When it does, the requirement is "fresh enough
  by the next recall read", which a per-turn pulse over-delivers on — so cadence tuning can only
  get *cheaper* from here, never tighter.

---

## Tests

- **Core, `async: true`, no db, no network:** `stale?/2` — zero pending never stale, exactly
  `max_lag` pending not stale, one past it stale. The old head-arithmetic cases leave with the
  old arithmetic; the suite shrinks to one comparison's worth, which is the point.
- **Store, `Bighead.DataCase`:** `count_since/2` against the gapped seqs that forced the rewrite —
  messages at seqs 3, 17 and 40 count 3 from −1, 2 from 3, 0 from 40; a second run in the same
  app is invisible; a `nil` `app_id`/`run_id` scope matches through the same `IS NULL` handling
  `for_run/1` uses.
- **Boundary, `Bighead.DataCase` + `Bighead.LLM.Stub`** — the first suite that needs both stores and
  the stub, which is the point of the composition: a fresh run returns `:fresh` and
  `Stub.calls/0` stays empty; a run holding more than `max_lag` messages and no summary produces
  `{:ok, summary}`, `latest/1` now returns it, and `through_seq` equals the run's max `seq`; a
  stale existing summary regenerates; an LLM error and a blank reply each leave the previous row
  latest.
- **Async, no sleeps:** `refresh_async/2` with `notify_pid: self()` then
  `assert_receive {:refreshed, ^scope, result}`; a telemetry handler forwarding to the test pid
  asserts the outcome tag and that metadata carries identifiers only — no summary text.
- **Controller:** `POST /hooks/stop` answers 200 with the inert body on a well-formed payload, a
  payload with no `session_id`/`cwd`, and a garbage payload alike; the wiring is asserted through
  the forwarded telemetry event, not by sleeping.
- **Hand-run smoke, the Phase 6 way:** a real transcript through the live path — backfill past
  `max_lag`, pulse, `latest/1` returns a summary whose `through_seq` is the transcript head; a
  second pulse with nothing new answers `:fresh` with zero LLM calls; dev logs grepped for a
  canary string from the summary.

## Exit criteria

- [ ] A live session grows a summary by existing: hand-run smoke lands a row, and the quiet
      follow-up pulse makes no LLM call
- [ ] The `Stop` route answers inside the sender's 5s budget even on a turn that regenerates —
      the response races nothing
- [ ] `through_seq` of a stored summary equals the max `seq` of the messages it covered, and
      `lines_seen/1` appears nowhere in the refresh path — §7.4's off-by-one dissolved, not
      patched
- [ ] `regenerate/2` byte-identical to Phase 7; `stale?/2` rewritten in message units with its
      suite; `mix test.core` green with the Postgres container stopped
- [ ] No summary text in any log at default dev configuration, telemetry metadata included —
      canary method
- [ ] `mix precommit` green

## Explicitly out of scope

**No lock and no queue** — the duplicate-regeneration race is argued benign above; a Registry
keyed by scope is the documented escape hatch, unbuilt. **No sweeper and no clock process** —
periodic-ness comes from the pulse. **No recall-time catch-up**: a session killed before its
final pulse stays stale until it speaks again, accepted because the recent window covers the tail
and nothing reads `S` yet anyway. **No server-side fallback trigger** for an installed `stop.py`
that predates the pulse — this is a local install whose sender ships in this repo. **No `Prompt`,
no φ(P), no change to `Extract` or recall** — `S` is now continuously fresh and still unread.
**No app- or user-rung summaries, no incremental refresh, no chunked map-reduce** — all re-parked
exactly where Phase 7 left them.

## Open questions this phase deliberately leaves open

| Question | Why not here | Shape it lands on |
| --- | --- | --- |
| Retuning `max_lag` past 10 | The value is back in its intended unit but still untuned; only live cadence data can rank token cost against usefulness | the `[:bighead, :summarize, :refresh]` outcome ratio, read after real use |
| Dead runs stay stale forever | Needs a reader to matter, and `S` has none yet | `refresh_async/1` from `user_prompt_submit` on a resumed run — the natural catch-up site once recall reads summaries |
| A sender that never pulses | Repo-shipped script, local install; version skew is a deployment problem this phase does not have | a degraded fallback trigger from `backfill`, or versioning the hook API |
| When `S` feeds recall and extraction | That is `Prompt` and φ(P), a phase of its own — and it sets the real freshness SLA (§8.5) | `Extract.facts/1` taking a `Prompt.t()`; `user_prompt_submit` reading `latest/1` up the covering ladder |
