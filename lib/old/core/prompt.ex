defmodule Mem0.Core.Prompt do
  @moduledoc """
  A prompt is a triplet that is being fed into the extractor to extract facts.
  Facts are not yet memories, but rather candidates for storage.


  To extract facts, the function `Φ(P)` needs a prompt `P`.

  A prompt contains a summary, a list of recent messages, and a new message
  pair.

  `P = (S, {m_{t-m}..m_{t-2}}, m_{t-1}, m_t)`

  In this implementation we collapse the recent pair into the list of messages,
  since we can have more than 2 messages per answer from an agent.

  `summary` is optional because at the head of a new conversation there is no
  `S` yet.
  """

  use TypedStruct

  alias Mem0.Core.Message
  alias Mem0.Core.Scope
  alias Mem0.Core.Summary

  typedstruct enforce: true do
    field :scope, Scope.t()
    field :summary, Summary.t(), enforce: false
    field :recent, [Message.t()]
    field :new, [Message.t()]
  end

  @doc """
  Builds an extraction prompt. `summary` defaults to `nil`; everything else is
  required.
  """
  @spec new(keyword()) :: t()
  def new(fields) do
    fields
    |> Keyword.put_new(:summary, nil)
    |> then(&struct!(__MODULE__, &1))
  end

  @doc """
  Assembles a prompt from a run's history, split at a watermark.

  - `:messages` — the run's stored history, in any order. Sorted by `seq` here,
    so the output does not depend on what order a caller held the list in.

  - `:last_message_seq` — the `seq` of the last message the previous extraction
    consumed. This is the line number in the transcript, so not consecutive
    numbering. If this value is nil, the whole list of messages is extracted.


  - `:summary` — `Mem0.Core.Summary.t/0` or `nil`, defaults to `nil`.

  `last_message_seq` is its own parameter, not the summary's `through_seq`: the
  two watermarks measure different things and legitimately disagree. `S` may lag
  up to `max_lag` behind the head by design, while `last_message_seq` marks
  where the last extraction stopped; the messages between them are exactly the
  recent context that covers the summary's gap.

  An empty new slice — an empty run, or a watermark at or past the head — is
  `{:error, :nothing_new}`: one error for one meaning, no call should be made.

  ## Examples

      iex> scope = Mem0.Core.Scope.new(user_id: "christophe")
      iex> message = fn seq ->
      ...>   Mem0.Core.Message.new(
      ...>     id: "m-" <> Integer.to_string(seq),
      ...>     scope: scope,
      ...>     role: :user,
      ...>     content: "message " <> Integer.to_string(seq),
      ...>     said_at: ~U[2026-01-01 00:00:00Z],
      ...>     seq: seq
      ...>   )
      ...> end
      iex> {:ok, prompt} =
      ...>   Prompt.from_history(messages: [message.(3), message.(17)], last_message_seq: 3)
      iex> {Enum.map(prompt.recent, & &1.seq), Enum.map(prompt.new, & &1.seq)}
      {[3], [17]}
      iex> Prompt.from_history(messages: [message.(3)], last_message_seq: 3)
      {:error, :nothing_new}

  """
  @spec from_history(keyword()) :: {:ok, t()} | {:error, :nothing_new}
  def from_history(opts) do
    opts
    |> Keyword.fetch!(:messages)
    |> Enum.sort_by(& &1.seq)
    |> split(Keyword.get(opts, :last_message_seq))
    |> build(Keyword.get(opts, :summary))
  end

  defp split(messages, nil) do
    {[], messages}
  end

  defp split(messages, last_message_seq) when is_integer(last_message_seq) do
    Enum.split_while(messages, &(&1.seq <= last_message_seq))
  end

  defp build({_recent, []}, _summary) do
    {:error, :nothing_new}
  end

  defp build({recent, [%Message{scope: scope} | _rest] = new_messages}, summary) do
    {:ok, new(scope: scope, summary: summary, recent: recent, new: new_messages)}
  end
end
