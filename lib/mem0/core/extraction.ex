defmodule Mem0.Core.Extraction do
  @moduledoc """
  An extraction (Ω) is a set of facts (ω) extracted from a prompt.

  An extraction is built by a prompt in a specific scope, and that scope's
  messages.

  The prompt that produces one lives here too, with the two pure halves of the
  call around it: `request/1` builds what the model is asked, and `decode/4`
  turns what it answers into facts. The call in between is `Mem0.Extract`'s job,
  because it is the only part that needs a clock and a network — which is what
  lets the prompt be iterated against fixture transcripts with no API key and no
  session in the loop.
  """

  use TypedStruct

  alias Mem0.Core.Fact
  alias Mem0.Core.Message
  alias Mem0.Core.Scope

  typedstruct enforce: true do
    field :scope, Scope.t()
    field :prompt_at, DateTime.t()
    field :facts, [Fact.t()], default: []
    field :source_message_ids, [Message.id()], default: []
  end

  # Caps rather than configuration: they move when the prompt moves, and a knob
  # nobody turns is a knob that rots. Phase 4 measured a 0.45 MB worst-case
  # batch, so without a bound one tool-heavy turn is a six-figure-token call.
  @max_messages 20
  @max_chars 2_000

  @system_prompt """
  You extract durable facts about a developer from their conversation with a
  coding agent.

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

  Rules:

  - Base facts on what the user said. Assistant turns are context for reading
    the user, never a source of facts about them.
  - One self-contained statement per fact, short and in the third person, so it
    still reads correctly with no conversation around it.
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
  The completion request that extracts facts from `messages`.

  One place builds it, so the live test and the boundary send the same bytes.
  """
  @spec request([Message.t()]) :: Mem0.LLM.request()
  def request(messages) do
    %{
      messages: [%{role: :user, content: render(messages)}],
      schema: @response_schema,
      system: @system_prompt
    }
  end

  @doc """
  Renders `messages` as the transcript the model reads.

  Ordered by `seq` and bounded on both axes: the last #{@max_messages} messages,
  each truncated at #{@max_chars} characters. The sort is not redundant with
  `Mem0.Ingest` — this is a pure function and its output should not depend on
  what order a caller happened to hold a list in.

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
      iex> Extraction.render([message.(:assistant, "Noted.", 2), message.(:user, "I use Elixir.", 1)])
      "user: I use Elixir.\\n\\nassistant: Noted."

  """
  @spec render([Message.t()]) :: String.t()
  def render(messages) do
    messages
    |> Enum.sort_by(& &1.seq)
    |> Enum.take(-@max_messages)
    |> Enum.map_join("\n\n", &"#{&1.role}: #{truncate(&1.content)}")
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
