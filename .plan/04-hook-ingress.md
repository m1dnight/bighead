# Phase 4 — Hook ingress

**Goal:** a real Claude Code session can post its conversation to bighead over HTTP, and bighead turns it
into `Bighead.Core.Message` structs — validated, attributed to a scope, tolerant of a format it does
not control, and unable to break the session that sent it. **The phase terminates at that data.**
No extraction, no embedding, no persistence, no recall, and no call into the `Bighead` boundary, which
does not exist yet.

> Phase 3.5 built a throwaway version of this: a controller that logged its payload, and a
> `jq`-and-`curl` hook script. Everything below is the robust replacement. The transcript fields it
> names were read off real sessions on this machine — see 4.1 for which are measured and which are
> assumed.

## Why a surface now, ahead of the pipeline

The overview's fourth sequencing principle is *surfaces last*: REST, MCP and the hooks are thin
wrappers over a `Bighead` boundary, cheap once the boundary is right and worthless before. Taken
literally, this phase violates it.

It does not, and the distinction matters. What this phase delivers is **a pure function from Claude
Code's transcript format to `[Message.t()]`** — data, in the DFTBLW sense, arriving before the
behaviour that consumes it. The controller is a thin skin over that function.

The reason to do it now rather than after the pipeline is that every prompt in Phase 5 is written
*against* this shape: what counts as a message, whether a tool result is one, what is left of an
assistant turn once its thinking blocks are gone. Guessing that and writing prompts against the
guess is the expensive order.

### What "no boundary" means concretely

`Bighead.Core.Message` is core *data*, not a boundary — the layering test forbids anything under
`Bighead.Core.*` from reaching a `Repo`, an HTTP client, a process or a clock, and a boundary is
defined by doing exactly those things. Having the struct means having the vocabulary the boundary
will speak, not the boundary. `lib/bighead.ex` is still the generated moduledoc.

So this phase adds **one small boundary of its own, and it terminates.** `Bighead.Ingest` validates,
builds a `Scope`, calls the normaliser, emits telemetry and broadcasts. Its only effects are a
telemetry event and a `PubSub` message. It calls nothing downstream, because there is nothing
downstream: no `Bighead.remember/2`, no `Repo`, no LLM, no embedder. The messages it produces are
handed to a dev LiveView and then dropped on the floor.

That is the point of doing it now. Its output is Phase 5's *input* — real messages, in the real
shape, from real sessions — available to write prompts against before the machinery that consumes
them exists. The seam is `Bighead.Ingest.receive/2`; Phase 5 changes what happens to the list it
returns, and nothing about the parsing changes.

---

## 4.1 The transcript is not a public contract

Claude Code's session transcript is an internal JSONL file. Its schema is not documented, not
versioned, and not promised to be stable. It also **changes between patch releases** — `origin`
(4.3) appears in v2.1.224 and is absent from v2.1.223, and both versions are represented in the
transcripts already on this machine.

That produces the phase's central rule:

> **The normaliser must never fail the request.** An entry it does not understand is dropped and
> counted, never raised on.

Concretely: no `Map.fetch!/2`, no `struct!/2` on payload-derived data, no pattern match that assumes
a key. A `case` with a catch-all returning `{:drop, reason}` on every path. When Claude Code ships a
new entry type, bighead keeps ingesting the ones it recognises and the drop counter says something
changed. The failure mode of the alternative is a `UserPromptSubmit` hook returning 500 and every
prompt in every session stalling behind it.

This is also why the parse is total rather than a changeset. `Ecto.Changeset` is right for a
contract *you* define and a caller violates. Here neither side is at fault and there is no error to
report to anyone — the only useful output is what could be read, plus how much could not.

**The rule starts after JSON decoding, and that boundary is real.** `stop.sh` splices raw transcript
lines into a JSON array textually, so a line torn by a concurrent append does not arrive as one
unreadable entry — it makes the whole body unparseable, and `Plug.Parsers` rejects it before the
normaliser is reached. Nothing below can recover that batch. What makes it survivable is overlap:
the tail is re-sent on the next `Stop`, so a batch lost to a torn read is re-offered a turn later.
Tolerance inside the parser and overlap outside it cover different failures, and both are needed.

### What is measured and what is assumed

Confidence in these is not uniform, and the implementer should know which is which:

| Field | Status |
| --- | --- |
| `type`, `uuid`, `timestamp`, `sessionId`, `cwd`, `version` | **measured** — present on every entry sampled |
| `message.content` as string or block list | **measured** |
| `origin.kind`, and its correlation with human authorship | **measured** — see the table in 4.3 |
| `toolUseResult`, `isSidechain` | **measured** |
| `isMeta` | **measured** — 73 conversation entries carry it, none human-authored |
| compaction markers | **measured** — a manual `/compact` was captured after the fact; see below |

The assumed rows are exactly where a wrong guess costs a real message, so verify them first.

> **Compaction, measured after implementation.** A `/compact` was run deliberately and captured as
> `test/support/fixtures/transcripts/compacted.jsonl`. The guess held: the summary is a `type: "user"`
> entry carrying `isCompactSummary: true` (and `isVisibleInTranscriptOnly: true`), preceded by a
> `type: "system"`, `subtype: "compact_boundary"` entry whose `compactMetadata` names the preserved
> segment. Rule 2 drops the summary as `:meta` and rule 1 drops the boundary, both without change.
>
> It surfaced one thing the rules did *not* cover: a slash command reaches the transcript twice, and
> the second copy is the raw text the user typed — no wrapper, and on v2.1.241 no `origin` key
> either, so neither of rule 4's two tests fired and `/compact` was ingested as a message. Measured
> across the corpus that was one entry in 169 kept user messages, with no false positive. Rule 4 now
> has a third test: content that is exactly one `/token`. `\w` excludes `/`, so `/dev/ingest` and any
> sentence merely opening with a slash are still kept.

---

## 4.2 `Bighead.Core.Transcript.ClaudeCode`

The spine of the phase. Pure, in the core, no clock, no I/O.

**Named for the format it parses, not generically.** A second source — Cursor, an OpenAI export, a
plain chat log — is a sibling module returning the same `[Message.t()]`, and the `Transcript`
namespace is left free in case one ever justifies a behaviour.

```elixir
defmodule Bighead.Core.Transcript.ClaudeCode do
  @type entry :: map()

  # Ordered as the rules are applied: cheap structural rejections first,
  # content-level ones last.
  @type drop ::
          {:unsupported_type, String.t()}
          | :meta
          | :sidechain
          | :synthetic
          | :tool_result
          | :no_text
          | :unparseable_timestamp
          | :malformed

  @doc """
  Normalises decoded transcript entries into messages, oldest first.

  `offset` is the transcript line the batch starts at, so that `seq` is
  absolute within the run rather than relative to this batch. Returns the
  messages it could read and a reason for each entry it could not.
  """
  @spec messages([entry()], Scope.t(), non_neg_integer()) :: {[Message.t()], [drop()]}
  def messages(entries, scope, offset \\ 0)
end
```

Three deliberate choices in that signature.

**It returns the drops.** Not `[Message.t()]`, not `{:ok, _} | {:error, _}`. A partial parse is the
normal case, and the count of what fell out is the only early warning that the upstream format
moved. It feeds the telemetry in 4.9.

**`offset`, not an implicit index.** `stop.sh` tail-slices the transcript, so the first entry of a
batch is not the first entry of the run. Numbering from zero each time would give two different
messages the same `seq`, breaking `Message`'s own documented meaning — *orderings of messages within
a single run*. The script has to send where its slice starts; without it the field is a lie.
**This is the single most likely thing to be got wrong in this phase.**

**`seq` counts transcript lines, not kept messages, and that is deliberate.** The script sends
`total_transcript_length` (lines in the file) and `transcript_length` (lines in this batch), so
`offset = total_transcript_length - transcript_length` and an entry's `seq` is its line position in
the run. That makes `seq` sparse — every entry 4.3 drops burns a value — which costs nothing,
because `seq` orders messages and does not count them. What it buys is stability: a message's `seq`
is a fact about the file, so it does not move when a drop rule changes. Numbering the *kept*
messages instead would silently renumber an entire run the day rule 4 gets stricter.

`parentUuid` does not remove the need for it. The chain gives a total order *within* a batch — which
JSONL line order already gives for free — but the parent of the batch's first entry is a uuid that
was sliced away, so it says nothing about where the batch sits in the run. Order is not position.

The two counts also let the boundary check `length(entries) == transcript_length`, which catches a
torn or miscounted slice before its `seq` values are believed. This is weaker than the
`offset + length == total` an entry-counting client could support: it cannot detect a wrong
`total_transcript_length`, because nothing inside the batch witnesses the file's true length. The
script counting lines with `wc -l` (newlines) and entries with `grep -c ''` (lines, including an
unterminated last one) is exactly how the two disagree, on the file whose last line is being
appended to right now.

**No `now` argument, and therefore no clock.** An entry whose `timestamp` will not parse is dropped
as `:unparseable_timestamp` rather than stamped with the current time. Inventing a `said_at` for a
message whose real one is unknown corrupts every temporal predicate downstream, and the entries that
would need it are exactly the malformed ones nobody wants. This satisfies
`test/bighead/core/layering_test.exs`'s clock rule by construction rather than by care.

### Why not a behaviour

The instinct is to make this a port like `Bighead.LLM`, so a second agent's format drops in behind the
same contract. Three reasons not to, yet:

- **The Phase 3 ports isolate I/O; this isolates nothing.** `Bighead.LLM` earns its behaviour because
  the stub is a real second implementation doing a real job — a suite with no network and no keys.
  A stub transcript parser has no job: the parser is already pure and fixtures test it directly. One
  implementation and no test-driven second one is the definition of a premature abstraction.
- **The format is a property of the request, not the deployment.** A config-selected adapter picks
  one at boot, which is right for `BIGHEAD_LLM_PROVIDER`. Two agents posting to the same instance need
  both parsers live at once, selected per route or per payload — a router entry, not a behaviour.
- **The callback would be wrong.** Sources differ in what they can say about identity: an export
  with no `session_id` and no `cwd` derives its `Scope` differently. That derivation belongs in the
  boundary above the parser, which is why `messages/3` takes a `Scope` rather than building one.

The seam that matters is the return type. Any second source is a module returning `[Message.t()]` —
a new file, not a changed contract. Promote `Bighead.Core.Transcript` to a behaviour on the day there
is a second parser and the two agree on a signature, not before.

---

## 4.3 Which entries count as something someone said

Rules applied in this order. Each rejection is cheaper than the one after it, and the ordering is
what makes the drop reason meaningful — an entry gets the *first* reason that applies.

| # | Rule | Drop reason |
| --- | --- | --- |
| 1 | `type` is neither `user` nor `assistant` | `{:unsupported_type, type}` |
| 2 | `isMeta`, summaries, snapshots | `:meta` |
| 3 | `isSidechain: true` | `:sidechain` |
| 4 | a `user` entry that no person authored (below) | `:synthetic` |
| 5 | a `user` entry carrying `tool_result` blocks | `:tool_result` |
| 6 | an `assistant` entry with no `text` block left | `:no_text` |
| 7 | `timestamp` will not parse | `:unparseable_timestamp` |
| 8 | anything else that does not fit the shape | `:malformed` |

### `role: "user"` does not mean "a person typed this"

Claude Code puts a great deal of machine-authored text in the user turn, because that is the only
envelope the Messages API gives it: slash-command invocations, their stdout, `<system-reminder>`
blocks, IDE context, skill preambles, subagent briefs. All arrive as `type: "user"` with
`role: "user"`. Ingesting them means remembering things nobody said.

There is a structural field for this and it beats sniffing content. Measured across the transcripts
on this machine:

| Signal | Meaning | Evidence |
| --- | --- | --- |
| `origin.kind == "human"` | a person typed it | on v2.1.241, 19/19 such entries were typed prompts |
| `origin.kind` present, other value | machine-generated | `task-notification` seen; treat the set as open |
| `origin` absent entirely | **the version predates the field** | v2.1.223 and most of v2.1.238 emit none |

That last row is why `origin` cannot be used alone: it is recent, so an allow-list on it silently
discards every real prompt in an older session. Two **independent** tests instead, and an entry must
pass both:

1. **Wrapper strip** — join the entry's `text` blocks, remove every known wrapper block, trim.
   Nothing left → `:synthetic`. Version-independent; this is what catches slash commands.
2. **Origin check** — `origin` present and `kind != "human"` → `:synthetic`. Catches machine
   entries carrying no recognisable wrapper. Absent `origin` simply does not fire this test.

Two independent tests rather than a fallback chain, because a fallback needs to distinguish
"`origin` absent because the version is old" from "absent because the entry is synthetic", and
nothing in the payload answers that. Neither test needs to know.

### What a slash command actually looks like

One invocation produces two or three *separate* entries, all `type: "user"`, none with `origin`:

```
<command-name>/effort</command-name><command-message>effort</command-message><command-args></command-args>
<local-command-stdout>Set effort level to low (saved as your default for new sessions)…</local-command-stdout>
```

Each is entirely wrapper, so each strips to empty and drops as `:synthetic`. A `/compact` adds a
third, `<local-command-caveat>`, sometimes concatenated into the same entry as the other two —
which is why the strip removes *all* known blocks before testing for emptiness rather than matching
the whole content against one pattern.

### The tag list is a closed allow-list, and must stay one

The wrapper names, measured across the transcripts on this machine:

```
command-name  command-message  command-args  local-command-stdout
local-command-caveat  system-reminder  ide_opened_file  ide_selection
task-notification
```

**Do not generalise this to "content that looks like a tag".** Genuine prose in the same corpus
opens with `<text>` 117 times, `<script>` 107, `<query>` 39, `<package>` 24, `<version>` 15 — all of
them people discussing HTML, jq and hex packages. A heuristic would eat real messages; only a closed
list is safe. An unrecognised wrapper is therefore *kept*, and the cost is noise rather than loss.

Mechanics that the real data forces:

- **Content may be a block list, not a string.** Every user entry in the sampled sessions is a block
  list. Join the `text` blocks first, then strip.
- **Wrappers are not well-formed XML and are not always balanced.** A dangling `<ide_selection>` with
  no close, and an orphan `</task-notification>` with no open, both occur. Strip a known opening tag
  to end-of-input, and a leading orphan closing tag, rather than requiring a pair.
- **Distinguish `:synthetic` from `:no_text`.** An entry that strips to empty is machine text; an
  entry with no `text` blocks to begin with is something else (12 human-authored entries in the
  corpus are empty). They are different signals and conflating them hides both.

Validated against the corpus: of 183 entries with `origin.kind == "human"`, 33 had a wrapper
stripped and **none lost its human half** — a real message carrying an appended `<system-reminder>`
or `<ide_opened_file>` keeps its text, because the strip removes the block and keeps the remainder.

`origin.kind` is vendor data and stays a binary — no `String.to_atom/1`, per `AGENTS.md`.

### Retracted turns are ingested, and that is a deliberate debt

**The transcript is a tree, not a list.** Rewinding a turn or editing an earlier message forks the
conversation — two entries share a `parentUuid` — and the file keeps both branches, because it is
append-only. Line order therefore includes turns the user explicitly took back, and this phase
ingests them. For a memory system that is a correctness bug rather than an untidiness: the user
rewound precisely because they did not mean it, and no later phase can tell the difference.

It is deferred anyway, because the measurement says the rule is nearly all risk and almost no yield.
Across the local corpus, 19 of 1546 conversation entries sit off the main `parentUuid` chain — and
17 of those are already discarded by rules 4 and 5 as `:synthetic` or `:tool_result`. Pruning would
newly catch **two entries in 1546**.

Against that: the rule walks back from the last surviving entry and drops everything unreachable, so
it is the one rule in 4.3 that can discard something a person really typed. The fork behaviour it
depends on is assumed rather than measured, and no human-authored entry in the corpus was ever
off-chain — meaning the rule has never been exercised on the case that would prove it safe. Buying
two entries per 1546 with a rule that can eat real prompts, against unverified semantics, is the
wrong trade until a real rewound transcript exists to test against.

Recorded in the open questions with its cost, not forgotten.

---

## 4.4 What survives inside a kept entry

Entry-level rules decide *whether*; these decide *what*.

| Block | Becomes | Why |
| --- | --- | --- |
| `text` | the message content, blocks joined | The thing actually said |
| `thinking` | dropped | Not said to anyone — the same filter the Anthropic adapter already applies |
| `tool_use` | dropped | A function call, not an utterance |
| `tool_result` | drops the whole entry (`:tool_result`) | **See below** |

A `user` entry's content may be a bare string or a block list; both are normal and both must parse.

**Dropping tool results is the one non-obvious call, and it is the important one.** In the
transcript a tool result arrives as a `type: "user"` entry, because that is how the Messages API
carries it. Keeping it would mean feeding Phase 5's extraction prompt a "user message" whose content
is a directory listing or a 4 000-line file, and asking a model to extract durable facts about a
person from it. That is where nearly all the tokens live and nearly none of the facts, and the
failure is silent: you get plausible-looking memories about file paths.

`Message.role` has no fourth value for it either. Adding one would push the decision into every
consumer instead of settling it once here.

The counter-argument is real and sits in the open questions: sometimes the fact *is* in the tool
result (`git config user.email`). The answer is not to widen the ingest but to let a later phase opt
specific tools in, with the fact taken from the *tool call*, not the blob.

---

## 4.5 Identity comes from the server, not the payload

`Scope.user_id` is the boundary between one person's memories and another's — `Scope.covering/1`
widens across apps and runs and never across users. So it must not be readable from the request
body, which is written by whatever process ran the hook.

| `Scope` field | Source | Trust |
| --- | --- | --- |
| `user_id` | a server-side default; the bearer token when auth lands | server |
| `app_id` | `basename(cwd)` from the payload | client |
| `run_id` | `session_id` from the payload | client |

**Authentication is deferred, and the rule above is what makes deferring it safe.** There is no
bearer token in this phase: `user_id` comes from `BIGHEAD_DEFAULT_USER_ID`, resolved in the boundary.
Nothing changes about where it may *not* come from — a payload claiming another user is still
attributed to the server's value, because the body is still never read for it. What is missing is
only the ability to have more than one user, and 4.8 records that as debt.

It stays a real binary rather than `nil`, because the `Scope` it builds is threaded through every
downstream filter; a `nil` there would shape the whole pipeline around a value that disappears the
day auth lands. When it does, `BIGHEAD_HOOK_TOKENS` maps token to `user_id`, compared with
`Plug.Crypto.secure_compare/2`, and the only line that changes is the one resolving the default.

`app_id` and `run_id` stay client-supplied because a wrong one mislabels a memory rather than
leaking it — the blast radius stops at the `user_id`.

`cwd` is a weaker signal than it looks. A real captured entry carries
`"cwd": "/Users/christophe/Library/Application Support"`, which would file memories under an
`app_id` of `Application Support`. Mislabelling, not leaking — but it is why the collision question
below is real rather than theoretical.

`Scope.new/1` already trims and normalises blanks to `nil`, so a hook sending `"cwd": ""` lands on
the user-global scope rather than raising. That is correct behaviour and it comes for free.

---

## 4.6 The boundary: `Bighead.Ingest`

**This is not `Bighead`.** It is a boundary whose only job is to get data in and stop. When `Bighead`
exists, `Bighead.Ingest` becomes one of its callers; today it calls nothing.

```elixir
@spec receive(payload :: map(), user_id :: String.t()) ::
        {:ok, [Message.t()], [ClaudeCode.drop()]} | {:error, term()}
```

The second argument is the server-resolved `user_id` — `BIGHEAD_DEFAULT_USER_ID` in this phase, the
token's user when auth lands (4.5) — and **not** a `Scope`. Building the `Scope` is this module's
job, because that is where server-trusted identity and client-supplied `cwd`/`session_id` are
combined, and 4.5's rule only holds if one place does it. Keeping the argument even though it has
exactly one possible value today is what makes auth a change to this module's *caller* rather than
to this module.

It validates (per the overview's *the core trusts its input; the boundary validates*), checks
`length(entries) == transcript_length` and derives
`offset = total_transcript_length - transcript_length` (4.2), builds the `Scope`, calls
`Transcript.ClaudeCode.messages/3`, emits telemetry, broadcasts on `Bighead.PubSub`, and returns.

It exists as a module rather than as controller code for one reason: validation and scope
construction are what a second surface would otherwise duplicate, and putting them in a Phoenix
controller is precisely the failure the *surfaces last* principle exists to prevent.

**No process, no `Task`, no queue.** The work is JSON decoding plus a list traversal — microseconds
per entry. A `Task.Supervisor` would buy nothing and cost the ability to return the parse result in
the response, which Phase 6's recall needs. If profiling against a real 5 MB transcript says
otherwise, that is a measurement to make then.

**No deduplication either.** The script re-sends its tail on every turn, and at a 100-line tail
those tails overlap heavily (4.10), so the same `uuid` arrives many times. The right place to settle that is a unique index on `uuid` at the store with
`on_conflict: :nothing` — Phase 5. An in-memory seen-set here would be a process holding state the
database is about to hold correctly, and it would forget everything on restart. Phase 4 returns
duplicates and says so.

---

## 4.7 The web surface

Two routes through the `:api` pipeline, with different jobs and different response contracts.

| Route | Event | Job | Response read? |
| --- | --- | --- | --- |
| `POST /hooks/stop` | `Stop` | ingest — the whole of this phase | no; `stop.sh` detaches |
| `POST /hooks/user-prompt-submit` | `UserPromptSubmit` | recall — nothing to recall yet | **yes**, synchronously |

**`MessageDisplay` was the original ingest point and has been removed** — route, action and script.
It fires per flush of the stream, and the message being flushed has not landed in the transcript
yet, so reconstructing a turn there meant accumulating `delta`s keyed by message id: per-message
state this boundary refuses to hold (4.6). `Stop` fires once, at the end of the turn, and needs
none of it.

> **Correction, measured after implementation.** This section assumed the transcript is complete
> when `Stop` runs. It is not: Claude Code flushes the turn's final assistant entry *after* the hook
> returns. On a real turn the entry was stamped `15:12:55.966`, the hook started `~15:12:55.99` and
> ran 63ms, and the file it read still ended one entry short — every earlier entry present, only the
> answer just produced missing. Overlap recovers it on the next turn, but the last answer of a
> session never would, and recall would lag a turn behind.
>
> **Reverted in Phase 6.** `Bighead.Ingest` did rebuild that message from the payload's own
> `last_assistant_message`, under the id `"pending:" <> prompt_id`. It was removed: that id is one
> no transcript will ever agree with, so the real entry arriving on the next turn is a second row
> with the same words and a different identity — a duplicate no primary key can catch and every
> consumer downstream has to know about. The measurement above stands; the cost of living with it
> is one assistant message per *session*, the last one, and mid-session nothing is lost because
> overlap carries the entry a turn later with its real uuid.

**The response contract gets a type.** Both shapes are camelCase keys that form a contract with an
external tool, and a typo in `hookSpecificOutput` fails silently — the hook simply has no effect,
with no error anywhere. A small module with a `@type` and one constructor per event.

```elixir
%{hookSpecificOutput: %{hookEventName: "UserPromptSubmit", additionalContext: ..., sessionTitle: ...}}
%{hookSpecificOutput: %{hookEventName: "Stop"}}
```

- **`decision` stays absent from both, for different reasons.** On `UserPromptSubmit`,
  `"decision": "block"` erases the prompt and shows `reason` instead of running it. On `Stop`, it
  sends Claude back to work instead of ending the turn — which is what `stop_hook_active` in the
  payload exists to detect.
- **`additionalContext` ships empty.** There is nothing to recall yet. It is where Phase 6 lands, and
  the type should carry it now so wiring it is one line later. `Stop` accepts the field too, as
  non-error feedback delivered to the model — a second injection point if end-of-turn recall ever
  earns its place.
- **200 unconditionally**, including on a parse that produced nothing. `UserPromptSubmit` blocks the
  session that fired it, so that route must never be why a turn stalls; `Stop`'s response is
  discarded by the script, so its body is inert by construction.

**Body size is not the constraint the last draft assumed.** Measured across the local corpus, a
100-line tail is 0.09 MB at the median, 0.25 MB at p90 and 0.45 MB at its worst — two orders of
magnitude under `Plug.Parsers`' 8 MB default. The limit stays configurable as a safety valve against
one pathological tool result, not as the thing standing between this phase and a 413. The script's
`LIMIT` remains the real control (4.10).

Bind the endpoint to loopback in dev regardless, and note that this matters *more* now than it did
when the route took a token: something that accepts conversation transcripts and, in this phase, no
credentials at all should not be reachable off-box by accident.

---

## 4.8 Configuration

All of it through `runtime.exs`, per `AGENTS.md`, with `.env.example` updated in the same commit.

```sh
# --- Claude Code hook ingress -----------------------------------------------
BIGHEAD_DEFAULT_USER_ID=christophe   # until bearer tokens land (4.5)
BIGHEAD_HOOK_MAX_BODY=16777216       # bytes; a safety valve, not the real control
```

`BIGHEAD_DEFAULT_USER_ID` falls back to something like `"local"` rather than being required. An install
with no configuration should ingest: there is nothing to protect yet, and a hard failure at boot is
a worse first experience than a memory filed under a placeholder name.

**That default is open, and it is the one place this phase is deliberately less safe than the
previous draft.** With `BIGHEAD_HOOK_TOKENS` the rule was that an unconfigured install rejects
everything with a 401, on the grounds that an open default fails silently and a closed one fails
with a log line. That reasoning is still correct and returns with auth. What suspends it here is
that there is no second user to keep out, and the loopback bind in 4.7 carries the weight in the
meantime. Record it as debt, not as a decision that was re-argued and won.

The scripts hardcode `http://localhost:4001` and send no token. `BIGHEAD_HOOK_URL` and
`BIGHEAD_HOOK_TOKEN` arrive with auth; reading them in the script is not a violation of the
`System.get_env`-only-in-`runtime.exs` rule, because the script is not the application.

---

## 4.9 Observability without payloads

`stop/2` currently does `IO.puts(inspect(params))`, and `log_payload/2` is a dormant second copy of
the same idea. Together they are the only place in the application that violates `AGENTS.md`'s
"never log prompts, completions or memory contents", and **removing both is an exit criterion of
this phase.**

Worth knowing before writing the replacement: Phoenix's own request logger already prints
`Parameters: %{...}` for every request in dev, so the transcript reaches the log twice today and
deleting the `Logger.info` fixes only half of it. The route needs its params filtered
(`config :phoenix, :filter_parameters`) as well.

What replaces it:

```
[:bighead, :ingest, :received]   %{entries: n, messages: n, dropped: n, duration: µs}
                              %{user_id: ..., app_id: ..., run_id: ..., hook_event: ...}
```

Counts and identifiers, no content — the same rule the LLM telemetry follows. Breaking the drop
count out by reason is worth the extra field: a sudden rise in `:malformed` or
`{:unsupported_type, _}` is the signal that Claude Code's format moved.

**Bucket `{:unsupported_type, type}` by the type string, never as an aggregate.** Fourteen entry
types appear in the local corpus and only two are conversation — `attachment` alone outnumbers
`user` entries. Rule 1 therefore drops more than half of every batch as a matter of routine, and an
aggregate counter would bury a genuinely new type under that known-constant majority. Per-type
counts turn the same data into the intended alarm: a bucket that did not exist last week.

Payload inspection stays behind the existing `config :bighead, :log_llm_payloads`, which already
defaults to `false` everywhere and is hard-`false` in test.

A dev-only LiveView at `/dev/ingest` subscribing to the broadcast replaces reading the log. It shows
normalised `Message` structs as they arrive, which is what you actually want to look at, and it does
not exist in production because it is behind `dev_routes`.

---

## 4.10 The hook scripts

Two of them, both deliberately stupid: read stdin, post, exit 0.

`scripts/hooks/stop.sh` is the ingest path. It posts the hook payload with the tail of the
transcript spliced on, as `entries` plus `total_transcript_length` and `transcript_length` (4.2). It
sends **raw lines rather than a filtered slice** — summaries, meta entries and tool results all go —
because deciding what counts as something someone said is 4.3's job, and that decision belongs on
the Elixir side where it is tested and versioned rather than in a `jq` filter nobody reads.

**`LIMIT` defaults to 100 lines, and the number is measured rather than picked.** Across the local
corpus the distance between consecutive human prompts is 13 lines at the median, 24 at p75 and 39 at
p90, with a worst case of 114. The earlier default of 10 therefore missed the prompt that opened the
turn on **63% of turns** — the single most fact-bearing entry in the batch, gone in the majority
case, and silently. 100 covers p90 with room and costs 0.09 MB at the median (4.7).

The heavy overlap that produces between consecutive turns is not waste. It is what makes a batch
lost to a torn read recoverable (4.1), and uuid dedup at the store settles the repeats (4.6).

`scripts/hooks/user-prompt-submit.sh` posts its payload and nothing else. It inlines no transcript,
because `stop.sh` reads the same file, and the only thing this event has to carry is the prompt
someone just typed and the session it belongs to.

Their invariants, which are the reason they are safe to run on every turn:

- **Always exit 0.** A non-zero exit interrupts the session, so a bighead that is down has to be
  invisible.
- **`user-prompt-submit.sh` writes nothing to stdout but bighead's response.** Claude Code reads that
  stdout as the hook result, so a stray `echo` becomes context in the conversation.
- **`stop.sh` writes nothing to stdout at all**, and detaches its `curl`. A `Stop` hook that prints
  `{"decision": "block"}` sends Claude back to work instead of ending the turn.

Neither is unit-tested and neither should be. Everything worth asserting is on the Elixir side; the
scripts' contract is "posts a JSON body with these keys and always exits 0", which is checked by
reading them.

---

## 4.11 Tests

- **Fixture transcripts** in `test/support/fixtures/transcripts/`, captured from real sessions and
  redacted, one per interesting shape: a plain exchange, a tool-heavy turn, a session with slash
  commands, a pre-`origin` session from an older version, and a session with a subagent. A
  **compacted session has to be produced deliberately** — nothing in the local corpus has ever been
  compacted, so rule 2's "summaries" arm is the one rule with no evidence behind it. Run a `/compact`
  and capture the result before implementing that arm. After the normaliser itself these are the phase's most valuable artifact
  — they are the record of a format nobody controls.
- **Normaliser tests**, `async: true`, no database, no tags: every rule in 4.3's table, the block
  rules in 4.4, `seq` arithmetic across two overlapping batches, ordering, and blank-scope
  normalisation.
- **A regression corpus check**: run the normaliser over every transcript in `~/.claude/projects`
  and assert no entry with `origin.kind == "human"` is dropped as `:synthetic`. It is the test that
  catches a wrapper-list edit going too far, and the corpus grows on its own. Keep it `@tag :corpus`
  and excluded by default — it depends on machine-local files.
- **A property test** (`stream_data` is already a dependency): for *any* generated JSON-shaped map,
  `messages/3` returns a tuple and does not raise. This is the direct test of 4.1's rule and the one
  most likely to catch a real bug.
- **Controller tests** through `BigheadWeb.ConnCase`: 200 from `/hooks/stop` on a real fixture body,
  200 on a body of garbage, 200 from `/hooks/user-prompt-submit`, the exact response key names for
  both, and a payload carrying its own `user_id` attributed to the configured default instead. Note that `ConnCase` sets
  `@moduletag :db`, so these are excluded from `mix test.core` even though the controller touches no
  database — either accept that or add a repo-less conn case.
- **No `:live` tests.** Nothing here calls a vendor.

---

## Exit criteria

- [ ] A real Claude Code session, with the hook wired, produces `Message` structs visible at
      `/dev/ingest` — the prompt is unaffected and the turn is not slowed perceptibly
- [ ] `messages/3` returns a tuple and never raises, on every fixture and under the property test
- [ ] `seq` is absolute within a run: two overlapping `Stop` batches from the same session agree on
      the `seq` of the messages they share, and a batch whose
      `length(entries) != transcript_length` is rejected
- [ ] A turn whose transcript span exceeds the 100-line tail still ingests the prompt that opened
      it, on a real tool-heavy session
- [ ] A session containing slash commands, their stdout and `<system-reminder>` blocks ingests none
      of them, and a transcript from a version predating `origin` still ingests its real prompts
- [ ] No entry with `origin.kind == "human"` is ever dropped as `:synthetic`, across the whole
      local transcript corpus
- [ ] No tool result is ever ingested as a user message
- [ ] `user_id` cannot be set from the request body — a payload claiming a different user is
      attributed to the configured default
- [ ] No request produces a 5xx, including on a body that is not JSON at all
- [ ] No transcript content appears in any log at default configuration, from bighead *or* from
      Phoenix's request logger
- [ ] `stop/2`'s `IO.puts` and the dormant `log_payload/2` are both deleted
- [ ] `mix test.core` still passes with the Postgres container stopped
- [ ] The layering test still passes — `Bighead.Core.Transcript.ClaudeCode` reaches no clock, no `Req`,
      no `Repo`
- [ ] `mix precommit` green

## Explicitly out of scope

No extraction, no embedding, no persistence, no Ecto schema for messages, and no `Bighead` public API —
`lib/bighead.ex` is untouched by this phase. No recall: `additionalContext` ships empty. No
deduplication (4.6). No authentication (4.5, 4.8). No pruning of retracted turns (4.3). No
`MessageDisplay` — it was built, measured and removed (4.7). No `PreToolUse`, no `SessionEnd`. No
MCP server. No retention or deletion of what was ingested, because nothing is stored yet.

## Open questions this phase deliberately leaves open

| Question | Why not here | Shape it lands on |
| --- | --- | --- |
| Whether specific tool results should be ingested | Needs the extraction prompt to exist before "is this a fact" can be judged | an allow-list keyed on `tool_name` |
| What a compaction boundary means for memory | A compact summary is a message nobody said, but dropping it loses the history it replaced | a `Message` role, or a separate struct |
| Whether subagent (`isSidechain`) turns are the user's conversation | Depends on whether memories are per-person or per-conversation | the `:sidechain` drop becoming a config flag |
| `app_id` collisions between two checkouts with the same basename | Only bites with more than one machine or checkout | git remote, or a hash of the full path |
| Whether retracted (rewound or edited) turns should be pruned | Worth two entries in 1546 today, and the rule can discard real prompts if the assumed fork behaviour is wrong (4.3) | a `parentUuid` walk, once a real rewound transcript exists to test against |
| When bearer tokens land | Nothing to protect while the endpoint is loopback-bound and single-user (4.8) | `BIGHEAD_HOOK_TOKENS` and an auth plug in front of both routes |
| Backpressure if a client posts a huge transcript every turn | Measured at 0.45 MB worst case over the local corpus; the tail-slice is the control and has two orders of headroom | the scoped `Plug.Parsers` limit |
| Whether `seq` should be assigned by the store at insert rather than by the client | The store knows the run's true length and cannot miscount; there is no store yet | `offset` disappearing from `messages/3` |
| Whether transcript parsing becomes a behaviour | Needs a second real format before a shared signature can be designed rather than guessed | `Bighead.Core.Transcript` as a `@behaviour` |
