# Transcript fixtures

Claude Code session transcripts, one JSONL entry per line, one file per
interesting shape. Field-for-field copies of real sessions on a real machine,
with identifiers and prose replaced — the structure is measured, the content is
not.

They exist because the format they capture is **not a public contract**: it is
undocumented, unversioned, and it changes between patch releases. `origin`
appears in v2.1.224 and is absent from v2.1.223, and both versions are
represented here. These files are the only record of that.

| File | What it captures |
| --- | --- |
| `plain_exchange.jsonl` | Two human turns and two assistant turns. String content and block-list content; a `thinking` block to drop; a real prompt carrying an appended `<ide_opened_file>` whose human half must survive. |
| `tool_heavy.jsonl` | A turn whose middle is tools. A `file-history-snapshot` and an `attachment` entry (neither is conversation), an assistant `tool_use`, and a `user` entry that is nothing but a `tool_result`. |
| `slash_commands.jsonl` | `/effort` and its stdout, an `isMeta` caveat, a `task-notification` origin — and one real prompt in the middle of them that must come through. |
| `pre_origin.jsonl` | v2.1.223, before `origin` existed. Its real prompt has no structural marker at all, so only the wrapper strip can tell it from the slash command above it. |
| `subagent.jsonl` | `isSidechain: true` turns interleaved with the main chain. |
| `compacted.jsonl` | A manual `/compact` on v2.1.241. The summary (`isCompactSummary` on a `user` entry), the `compact_boundary` system entry with its `compactMetadata`, an `away_summary` recap, and the raw `/compact` the user typed — which carries no wrapper *and* no `origin`, so only the bare-command rule catches it. |

## Adding one

Take a real session from `~/.claude/projects`, keep the entries that make the
point, and replace every identifier: `uuid`, `parentUuid`, `sessionId`, `cwd`,
paths inside content. Keep `type`, `timestamp`, `version`, `isMeta`,
`isSidechain`, `origin` and the `message.content` *shape* exactly as they were —
those are the things under test. Then add a row above.
