defmodule Mem0.Core.Extraction do
  @moduledoc """
  An extraction (Ω) is a set of facts (ω) extracted from a prompt.

  An extraction is built from a `Mem0.Core.Prompt`: `P = (S, recent, new)`
  """

  use TypedStruct

  alias Mem0.Core.Fact
  alias Mem0.Core.Message
  alias Mem0.Core.Prompt
  alias Mem0.Core.Scope
  alias Mem0.Core.Summary

  typedstruct enforce: true do
    field :scope, Scope.t()
    field :prompt_at, DateTime.t()
    field :facts, [Fact.t()], default: []
    field :source_message_ids, [Message.id()], default: []
  end

  # Caps rather than configuration: they move when the prompt moves, and a knob
  # nobody turns is a knob that rots. Phase 4 measured a 0.45 MB worst-case
  # batch, so without a bound one tool-heavy turn is a six-figure-token call.
  #
  # `@max_messages` denominates the *context* window — `recent` — which is what
  # it was always sized for. `new` is count-uncapped: every message in the
  # exchange is an extraction target, and nothing is ever silently excluded
  # from the extractor's view of the exchange. The char cap trims every
  # message in every section.
  @max_messages 20
  @max_chars 2_000

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

  # The reply shape `decode/4` expects, stated to the provider rather than
  # begged for in prose. `additionalProperties: false` so a model that decides
  # to also return its reasoning is rejected by the provider, not by us.
  @response_schema %{
    "additionalProperties" => false,
    "properties" => %{"facts" => %{"items" => %{"type" => "string"}, "type" => "array"}},
    "required" => ["facts"],
    "type" => "object"
  }

  @doc "Builds an extraction. `facts` and `source_message_ids` default to `[]`."
  @spec new(keyword()) :: t()
  def new(fields), do: struct!(__MODULE__, fields)

  @doc """
  The instructions the model is given.

  Public because it is the thing most worth diffing between iterations, and
  because a test asserting it was sent should not have to restate it.
  """
  @spec system_prompt() :: String.t()
  def system_prompt, do: @system_prompt

  @doc """
  The completion request that extracts facts from `prompt`'s new exchange.

  One place builds it, so the live test and the boundary send the same bytes.
  """
  @spec request(Prompt.t()) :: Mem0.LLM.request()
  def request(%Prompt{} = prompt) do
    %{
      messages: [%{role: :user, content: render(prompt)}],
      schema: @response_schema,
      system: @system_prompt
    }
  end

  @doc """
  Renders `prompt` as the sectioned user content the model reads.

  The prompp consists of the following:

   - The generic prompt
   - Earlier messages (the fixed # of messages to always add)
   - New messages to extract facts from.

  ## Examples

      iex> scope = Mem0.Core.Scope.new(user_id: "christophe")
      iex> message = fn role, content, seq ->
      ...>   Mem0.Core.Message.new(
      ...>     id: "m-" <> Integer.to_string(seq),
      ...>     scope: scope,
      ...>     role: role,
      ...>     content: content,
      ...>     said_at: ~U[2026-01-01 00:00:00Z],
      ...>     seq: seq
      ...>   )
      ...> end
      iex> prompt = Mem0.Core.Prompt.new(
      ...>   scope: scope,
      ...>   recent: [],
      ...>   new: [message.(:assistant, "Noted.", 2), message.(:user, "I use Elixir.", 1)]
      ...> )
      iex> Extraction.render(prompt)
      "# New messages (extract from these only)\\nuser: I use Elixir.\\n\\nassistant: Noted."

  """
  @spec render(Prompt.t()) :: String.t()
  def render(%Prompt{} = prompt) do
    [
      summary_section(prompt.summary),
      section("# Earlier messages (context)", recent_window(prompt.recent)),
      section("# New messages (extract from these only)", sorted(prompt.new))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  @doc """
  Turns the model's `reply` into an extraction in `scope`, stamped at `at`.
  """
  @spec decode(String.t(), Scope.t(), DateTime.t(), [Message.id()]) ::
          {:ok, t()} | {:error, :malformed_facts}
  def decode(reply, %Scope{} = scope, %DateTime{} = at, source_message_ids) do
    case Jason.decode(reply) do
      {:ok, %{"facts" => facts}} -> build(facts, scope, at, source_message_ids)
      _not_an_extraction -> {:error, :malformed_facts}
    end
  end

  defp summary_section(nil), do: nil
  defp summary_section(%Summary{text: text}), do: "# Conversation summary\n" <> text

  defp section(_header, []), do: nil

  defp section(header, messages) do
    header <> "\n" <> Enum.map_join(messages, "\n\n", &"#{&1.role}: #{truncate(&1.content)}")
  end

  defp recent_window(recent), do: recent |> sorted() |> Enum.take(-@max_messages)

  defp sorted(messages), do: Enum.sort_by(messages, & &1.seq)

  defp build(facts, scope, at, source_message_ids) when is_list(facts) do
    if Enum.all?(facts, &is_binary/1) do
      {:ok,
       new(
         scope: scope,
         prompt_at: at,
         facts: Enum.map(contents(facts), &fact(&1, scope, at, source_message_ids)),
         source_message_ids: source_message_ids
       )}
    else
      {:error, :malformed_facts}
    end
  end

  defp build(_facts, _scope, _at, _source_message_ids), do: {:error, :malformed_facts}

  defp contents(facts) do
    facts
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp fact(content, scope, at, source_message_ids) do
    Fact.new(
      content: content,
      scope: scope,
      extracted_at: at,
      source_message_ids: source_message_ids
    )
  end

  # `String.slice/3` hands back the same binary when there is nothing to cut, so
  # the match is how "was it truncated" is asked without measuring twice.
  defp truncate(content) do
    case String.slice(content, 0, @max_chars) do
      ^content -> content
      truncated -> truncated <> "…"
    end
  end
end
