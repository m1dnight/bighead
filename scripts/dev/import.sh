#!/usr/bin/env bash

shopt -s globstar


file=.transcripts/claude.jsonl
cat ~/.claude/**/*.jsonl > .transcripts/claude.jsonl
cat ~/.claude.bak/**/*.jsonl >> .transcripts/claude.jsonl

mkdir -p  .transcripts/claude
cp ~/.claude/**/*.jsonl .transcripts/claude/
cp ~/.claude.bak/**/*.jsonl .transcripts/claude/
rm -f .transcripts/claude/agent-*
rm -f .transcripts/claude/history.jsonl
rm -f .transcripts/claude/journal.jsonl

file=.transcripts/codex.jsonl
cat ~/.codex/**/*.jsonl > .transcripts/codex.jsonl

mkdir -p  .transcripts/codex
cp ~/.codex/**/*.jsonl .transcripts/codex/
rm -f .transcripts/codex/history.jsonl
rm -f .transcripts/codex/session_index.jsonl