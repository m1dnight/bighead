# Mem0

Implementation of Mem0 in Elixir.

## Mem0 Summary

Mem0 is a long-term memory store for LLMs so that they can retrieve information
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

## Mem0 Architecture

Mem0 ingests the conversations a user has with an LLM. A conversation `C` consists
of a list of `n` messages (`m_1..m_n`).

For each conversation `C` a summary `S` is generated. This is like a continuous
compaction of the pervious conversation.

### Extraction

If a new question/answer pair is sent to Mem0 (i.e., a user asked something, and
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

Search is how an agent consults Mem0 to get information to build its context.
Assume the user sends a prompt `m_1`. Before it is being sent to the agent, it
is augmented with information retrieval in mem0.

1. User types in prompt `m_1`.
2. Mem0 fetches the last 6 messages that came before `m_1` and adds them as is
  to the query.
3. Mem0 is searched in different ways to fetch relevant memories.
4. These memories are added to the prompt as plain text.
5. The prompt is sent to the LLM.


## Improvements

- Improve search (the way mem0 actually does it). Build a separate index for words (e.g., names, tech vocabulary, ..) and then do a word search, meaning search, and name search. This will yield a bigger set of potentially relevant resources.
- Look into how these system prompts can be injected across claude/codex etc. Claude has the option to append system messages, for example.
- We currently only store facts as memories, and do not store the graph search anymore. Mem0 itself no longer does it, and I have to investigate why. They now do event co-occurency storage or something similar: [https://mem0.ai/blog/introducing-temporal-reasoning-in-mem0](https://mem0.ai/blog/introducing-temporal-reasoning-in-mem0)
- Currently we don't take branching of conversations into account. We assume the conversation is one long list.
