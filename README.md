# Bighead

Implementation of Bighead in Elixir.


## Install

If you have the Bighead process running at `http://localhost:4000`, configure it as follows.

#### Claude

```bash
# Install the environment variable of your Bighead endpoint.
export f=~/.claude/settings.json
jq '.env += {"BIGHEAD_URL": "http://localhost:4000"}' "$f" > "$f.tmp"
mv "$f.tmp" "$f"
unset f
```

Move the scripts to your local `.claude` folder and hook them up in Claude.

```bash
mkdir -p ~/.claude/hooks/bighead && cp -r scripts/hooks ~/.claude/hooks/bighead
export f=~/.claude/settings.json
cmd="$HOME/.claude/hooks/bighead/hooks/hook.py"
jq --arg cmd "$cmd" '
  def h: {"hooks": [{"type": "command", "command": $cmd}]};
  def files: {"matcher": "Edit|Write|NotebookEdit|Bash"} + h;
  .hooks.SessionStart     += [h]
  | .hooks.UserPromptSubmit += [h]
  | .hooks.Stop             += [h]
  | .hooks.SessionEnd       += [h]
  | .hooks.PreToolUse       += [files]
  | .hooks.PostToolUse      += [files]
' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
unset f
```

## Bighead Summary

Bighead is a long-term memory store for LLMs so that they can retrieve information
from older conversations without relying on gigantic context windows.

There are three types of knowledge that an LLM can benefit from: content
reasoning, temporal reasoning, and open-domain reasoning.

In content reasoning, the LLM is fed a list of facts in natural language (e..g,
"The user is a vegetarian"). Asking questions about a user boils down to
checking if there is a statement about the user in the database of facts.
The LLM can reason about what is true, and why it is true.

Temporal reasoning allows the LLM to deduce if something was true, and when that
was true. For example, "I am a vegetarian" was recorded as a fact at time T1. A
few months later at T2 "I sometimes eat a nice juicy steak" is recorded.
Temporal reasoning allows the LLM to deduce that the user was strictly
vegetarian between T1 and T2 the user did not eat meat, but after T2, they did.
The LLM can reasn about when something was true, and how.

Open domain reasoning allows the LLM to deduce facts from memory using an
external memory (i.e., the model itself, or tools). E.g., "I like Alice Cooper"
is a fact. Using open domain reasoning the model can deduce that the user likes
rock music.

## Bighead Architecture

Bighead ingests the conversations a user has with an LLM. A conversation `C` consists
of a list of `n` messages (`m_1..m_n`).

For each conversation `C` a summary `S` is generated. This is like a continuous
compaction of the pervious conversation.

### Extraction

If a new question/answer pair is sent to Bighead (i.e., a user asked something, and
the llm responded), a new message pair `m_n+1, m_n+2` is available.

A "prompt" `P` is a triple `(S, C, m_n+1, m_n+2)`.

The function Φ takes as input a prompt `P` and returns a set of memories Ω =
`ω_1..ω_n`. These are proposed facts for the memory to store.

### Update

Given a set of extracted memories Ω, for each ω ∈ Ω the most similar tasks are
retrieved from the database using cosine similarity.

An LLM will for each new fact and existing similar facts, determine which of the
previous facts is outdated, not as accurate, or similar.

The result is then a set of operations to either delete, update, or add facts to
the database.

### Scopes

When a user is interacting with an agent it is identified by the user id, app
id, and run id. the user id is the operating system or username. The application
narrows the scope even further. This can be the git repo, directory, or
something else. The run id is the run id from the claude session. So each agent
session gets a unique id.

### Search

Search is how an agent consults Bighead to get information to build its context.
Assume the user sends a prompt `m_1`. Before it is being sent to the agent, it
is augmented with information retrieval in bighead.

1. User types in prompt `m_1`.
2. Bighead fetches the last 6 messages that came before `m_1` and adds them as is
  to the query.
3. Bighead is searched in different ways to fetch relevant memories.
4. These memories are added to the prompt as plain text.
5. The prompt is sent to the LLM.


## Ingestion Pipeline

Bighead gets its data purely through hooks (although you can submit backlogs of transcripts). There are two signals Bighead aims to ingest: transcripts and code changes.


### Transcripts

A transcript is a chat history with your agent. They are encoded as JSON Lines files. Each line contains a lot of meta data about your message; who sent it, what was the text, which session etc. Bighead ingests your intire transcript and filters server-side to only keep track of the useful bits. Each transcript exists within a "scope." A scope defines what the context of that transcript is: the user, the project you're working on, and the LLM session it is from.

The pipeline is roughly as follows:

```text
Post transcript to /v1/transcripts
--> decode json and extract the scope
--> extract relevant messages (only messages typed by the user, and sent by the agent)
```

At this point, only the actual messages are stored in the database. The actual processing of messages happens asynchronously.

```text
for all scopes that have new messages since last processing:
 - get all the messages (this is ~= your conversation with the llm)
 - Fetch all the known facts for this scope.
 - callout to LLM to extract natural language facts from the new messages.
 - for each new fact, reconcile them with the old facts:
   - for each pair of (new fact, old facts), call out to an LLM and ask it which facts are superseded, outdated, or new
   - store/update/delete facts based on the LLM's reply.
   - create an embedding for each new or updated fact
```

So assuming we have a set of facts for a given scope, we can now retrieve facts. Each time a user submits a prompt, the following happens.

```text
 - Create an embedding of the prompt the user is sending to your LLM.
 - Find facts that are relevant to this prompt in the database
 - Inject these facts into the prompt before passing it back to your LLM.
```

### Diffs

Another signal Bighead ingests is code diffs. This might not work for everyone, and especially not for full agentic coding, but it helps for us normies who still do prompt-guided developing. The idea is as follows. Each time you ask your LLM to generate a change to your project, Bighead listens for the changes it made. It keeps this version in mind. Next time anything happens, the file is revisited and a diff is made between the current version and the last written version by the LLM. The diff from this is a signal that contains what you think the LLM did wrong, and should do better in the future. Bighead keeps track of these diffs and sends them to the Bighead endpoint periodically. These diffs are processed as follows.

```text
 - For each new diff in the database:
    - Ask an LLM what this change contains. General changes that should be carried over to subsequent changes made by the LLM.
    - Store this guideline in the datbase.
```

## Improvements

- Improve search (the way bighead actually does it). Build a separate index for words (e.g., names, tech vocabulary, ..) and then do a word search, meaning search, and name search. This will yield a bigger set of potentially relevant resources.
- Look into how these system prompts can be injected across claude/codex etc. Claude has the option to append system messages, for example.
- We currently only store facts as memories, and do not store the graph search anymore. Bighead itself no longer does it, and I have to investigate why. They now do event co-occurency storage or something similar: [https://bighead.ai/blog/introducing-temporal-reasoning-in-bighead](https://bighead.ai/blog/introducing-temporal-reasoning-in-bighead)
- Currently we don't take branching of conversations into account. We assume the conversation is one long list.
- Work out a nice macro to measure the execution of function calls
- Maybe track the total token usage and actual USD cost as reported by the LLM.
