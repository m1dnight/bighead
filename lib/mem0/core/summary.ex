defmodule Mem0.Core.Summary do
  @moduledoc """
  A summary of a running conversation.

  The summary keeps a running compacted version of the entire chat history. This
  information is used to augment fact extraction in later phases. It's the only
  thing that actually has a good summary of the whole conversation to make fact
  extraction more precise.
  """

  use TypedStruct

  alias Mem0.Core.Message
  alias Mem0.Core.Scope

  @typedoc "How many messages `S` may fall behind the head before it needs redoing."
  @type max_lag :: non_neg_integer()

  # A placeholder, not a tuned value — see the module doc. It lives here rather
  # than in config so that changing it is a visible edit to the core.
  @default_max_lag 10

  # A cap per message, and deliberately no cap on the message count: every
  # message dropped from the render is a fact `S` can never state, and
  # regeneration is what makes the unbounded render safe — nothing is ever
  # silently excluded from the summary's view of history. The char cap trims
  # the one pathological pasted blob without losing the message. Unshared with
  # `Mem0.Core.Extraction`'s cap on purpose: each prompt's constants move when
  # that prompt moves.
  @max_chars 2_000

  @system_prompt """
  You distill one whole session between a developer and a coding agent into
  the running summary a reader needs to pick the session up cold.

  Cover, insofar as the transcript establishes them:

  - who the user is: role, expertise, stated preferences and habits
  - the project being worked on, and the constraints that bind it
  - decisions taken along the way, and the corrections the user issued
  - the user's stated goals, and where the work currently stands

  Do not include:

  - verbatim code, file contents, logs or tool output
  - a per-turn play-by-play of the conversation
  - anything the next turn is likely to make false: a test mid-failure, a
    file currently open, a command just run

  Rules:

  - Write prose in the third person, dense rather than exhaustive.
  - Prefer what the user said over what the assistant did; assistant turns
    are context for reading the user, not events worth recounting.
  - Do not infer past what was said, and do not invent detail.
  - Keep the summary under 350 words. The transcript grows on every read;
    the summary must not grow with it.
  """

  # The reply shape `decode/4` expects, stated to the provider rather than
  # begged for in prose. `additionalProperties: false` so a model that decides
  # to also return its reasoning is rejected by the provider, not by us.
  @response_schema %{
    "additionalProperties" => false,
    "properties" => %{"summary" => %{"type" => "string"}},
    "required" => ["summary"],
    "type" => "object"
  }

  typedstruct enforce: true do
    field :scope, Scope.t()
    field :text, String.t()
    field :generated_at, DateTime.t()
    field :through_seq, non_neg_integer()
  end

  @doc "Builds a summary. Every field is required."
  @spec new(keyword()) :: t()
  def new(fields), do: struct!(__MODULE__, fields)

  @doc """
  Whether the summary has fallen more than `max_lag` messages behind the
  conversation head.

  Takes the head `seq` rather than reading a clock, so the refresh policy is
  testable without a running pipeline. A summary that is level with the head, or
  ahead of it, is never stale.
  """
  @spec stale?(t(), non_neg_integer(), max_lag()) :: boolean()
  def stale?(%__MODULE__{} = summary, head_seq, max_lag \\ @default_max_lag)
      when is_integer(head_seq) and is_integer(max_lag) do
    head_seq - summary.through_seq > max_lag
  end

  @doc """
  The instructions the model is given to create a summary.
  """
  @spec system_prompt() :: String.t()
  def system_prompt, do: @system_prompt

  @doc """
  The completion request that summarises `messages`.

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
  Renders `messages` as the history the model reads.

  Ordered by `seq`, each message truncated at #{@max_chars} characters, and —
  unlike `Mem0.Core.Extraction.render/1` — with no message-count cap: the
  render grows with the session, and every message it is handed comes through.
  The sort is not redundant with the store's ordered read — this is a pure
  function and its output should not depend on what order a caller happened to
  hold a list in.
  """
  @spec render([Message.t()]) :: String.t()
  def render(messages) do
    messages
    |> Enum.sort_by(& &1.seq)
    |> Enum.map_join("\n\n", &"#{&1.role}: #{truncate(&1.content)}")
  end

  @doc """
  Turns the model's `reply` into the summary through `through_seq`, stamped at
  `generated_at`.

  Exactly two failure paths, and both are `{:error, :malformed_summary}`
  rather than a raise: a reply that does not parse to the agreed shape, and a
  reply that parses to a blank. A blank distillation of a non-empty
  conversation is a failed generation whatever the transport said, and storing
  it would replace a usable `S` with nothing — the caller gets an error, the
  previous row simply stays latest, and a lagging `S` is survivable by design
  because the recent window covers its gap.
  """
  @spec decode(String.t(), Scope.t(), DateTime.t(), non_neg_integer()) ::
          {:ok, t()} | {:error, :malformed_summary}
  def decode(reply, %Scope{} = scope, %DateTime{} = generated_at, through_seq)
      when is_integer(through_seq) do
    case Jason.decode(reply) do
      {:ok, %{"summary" => text}} -> build(text, scope, generated_at, through_seq)
      _not_a_summary -> {:error, :malformed_summary}
    end
  end

  defp build(text, scope, generated_at, through_seq) when is_binary(text) do
    case String.trim(text) do
      "" ->
        {:error, :malformed_summary}

      trimmed ->
        {:ok,
         new(scope: scope, text: trimmed, generated_at: generated_at, through_seq: through_seq)}
    end
  end

  defp build(_text, _scope, _generated_at, _through_seq), do: {:error, :malformed_summary}

  # `String.slice/3` hands back the same binary when there is nothing to cut,
  # so the match is how "was it truncated" is asked without measuring twice.
  defp truncate(content) do
    case String.slice(content, 0, @max_chars) do
      ^content -> content
      truncated -> truncated <> "…"
    end
  end
end
