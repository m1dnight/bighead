defmodule Mem0.Core.Summary do
  @moduledoc """
  A summary of a running conversation.

  The summary keeps a running compacted version of the entire chat history. This
  information is used to augment fact extraction in later phases. It's the only
  thing that actually has a good summary of the whole conversation to make fact
  extraction more precise.


  A summary belongs to a single agent's message history, so the `Scope` that's
  attached is only used for it's run id, which uniquely identifies a chat
  history, and therefore the summary.


  The `through_seq` field identifies the latest message in the history that has
  been used to generate the summary.

  If a given `run_id` has M messages, and the summary's `through_seq` is `M -
  max_lag`, it's considered outdated.
  """

  use TypedStruct

  alias Mem0.Core.Scope

  @typedoc "How many messages `S` may fall behind the head before it needs redoing."
  @type max_lag :: non_neg_integer()

  # A placeholder, not a tuned value — see the module doc. It lives here rather
  # than in config so that changing it is a visible edit to the core.
  @default_max_lag 10

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
end
