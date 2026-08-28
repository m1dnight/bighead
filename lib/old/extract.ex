defmodule Mem0.Extract do
  @moduledoc """
  Extracts facts from a run's conversation, with one LLM call.
  """

  alias Mem0.Core.Extraction
  alias Mem0.Core.Prompt
  alias Mem0.Core.Scope
  alias Mem0.LLM
  alias Mem0.Messages
  alias Mem0.Summaries

  @doc """
  Extracts facts from what `scope`'s run holds past `last_message_seq`, informed
  by the run's stored summary.

  Lets say we have messages `m_a...m_b...m_c..m_d`, and a summary `S` generated
  for `m_a` to `m_b`. Extraction can run for `(S, m_b..m_c)`. The next
  extraction should run for `(S, m_c..m_d)`.  `last_message_seq` is the index of
  the last extract message, so we do not extract from the same message twice.

  Returns `{:error, :nothing_new}` when there are no messages to extract from.
  """
  @spec facts_since(Scope.t(), integer() | nil, keyword()) ::
          {:ok, Extraction.t()} | {:error, term()}
  def facts_since(%Scope{} = scope, last_message_seq, opts \\ []) do
    with {:ok, prompt} <-
           Prompt.from_history(
             messages: Messages.for_run(scope),
             last_message_seq: last_message_seq,
             summary: Summaries.latest(scope)
           ) do
      facts(prompt, opts)
    end
  end

  @doc """
  Extracts facts from `prompt`'s new exchange.

  `opts` reaches `Mem0.LLM.complete/2` untouched, so one call can raise
  `max_tokens` or change the model without touching configuration.

  One instant stamps both the extraction's `prompt_at` and every fact's
  `extracted_at`. They differ by the latency of the call, and nothing consumes
  that difference.

  `source_message_ids` names the new slice's ids only: a fact cannot have come
  from a context section the prompt forbade as a source, so naming `recent`'s
  ids in provenance would be a lie in the data. A prompt with nothing new is
  refused before any call — a call that should never be made.
  """
  @spec facts(Prompt.t(), keyword()) :: {:ok, Extraction.t()} | {:error, term()}
  def facts(prompt, opts \\ [])

  def facts(%Prompt{new: []}, _opts) do
    {:error, :no_messages}
  end

  def facts(%Prompt{} = prompt, opts) do
    at = DateTime.utc_now()

    request = Extraction.request(prompt)

    with {:ok, response} <- LLM.complete(request, opts) do
      Extraction.decode(
        response.content,
        prompt.scope,
        at,
        Enum.map(prompt.new, & &1.id),
        through_seq(prompt)
      )
    end
  end

  # The extraction's extent: the seq of the last message in the new slice.
  # `new` is non-empty here — the empty case was refused above.
  defp through_seq(%Prompt{new: new_messages}) do
    new_messages |> Enum.map(& &1.seq) |> Enum.max()
  end
end
