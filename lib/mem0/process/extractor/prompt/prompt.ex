defmodule Mem0.Extractor.Prompt do
  @moduledoc """
  Renders a list of messages into the conversation block of the extractor's
  system prompt.
  """

  require EEx

  @template Path.join(__DIR__, "prompt.eex")
  @external_resource @template

  @system_prompt """
  You extract durable facts about a developer from their conversation with a
  coding agent.

  The prompt may open with a conversation summary and earlier messages. They
  are context for resolving references — "it", "there", "that approach" —
  never a source of facts. Extract only from the new messages.

  Extract a fact only if it would still be true, and still worth knowing, in a
  different session on a different project:

  - stated preferences and opinions — tools, languages, libraries, style
  - how they want to work — testing habits, review habits, what they want to be
    asked before it is done
  - constraints they state about themselves, their team or their environment
  - goals and plans they mention
  - corrections they make to the assistant, which are preferences stated the
    hard way
  - personal details they volunteer — role, timezone, what they are building

  Do not extract:

  - what the assistant did, said or proposed this turn
  - anything true only of this task: a file being open, a test currently
    failing, a command just run
  - contents of files, code, logs or command output
  - a restatement of what the conversation was about
  - anything stated only in the summary or the earlier messages

  Rules:

  - Base facts on what the user said. Assistant turns are context for reading
    the user, never a source of facts about them.
  - One self-contained statement per fact, short and in the third person, so it
    still reads correctly with no conversation around it. Use the context to
    resolve what a reference points at, and name the referent in the fact.
  - Do not infer past what was said, and do not invent detail.
  - Write each fact in the language the user used.
  - Most turns hold no durable fact. An empty list is the right answer far more
    often than not.
  """

  @doc """
  Renders the full system prompt: the extraction instructions followed by
  the given messages.

      Prompt.render(messages: messages)

  `@system_prompt` is filled in automatically; passing an explicit
  `:system_prompt` assign overrides the built-in instructions.
  """
  @spec render(keyword() | map()) :: String.t()
  def render(assigns) do
    assigns
    |> Map.new()
    |> render_template()
  end

  @spec system_prompt() :: String.t()
  def system_prompt, do: @system_prompt

  EEx.function_from_file(:defp, :render_template, @template, [:assigns])
end
