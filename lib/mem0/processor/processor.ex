defmodule Mem0.Processor do
  @moduledoc """
  Concerns itself with making sure all sessions in the database are properly extracted.
  """

  alias Mem0.Embeddings
  alias Mem0.Extractor
  alias Mem0.Reconciler
  alias Mem0.Store.Fact
  alias Mem0.Store.Facts
  alias Mem0.Store.Message
  alias Mem0.Store.Messages
  alias Mem0.Store.Scope
  alias Mem0.Store.Scopes

  require Logger

  # The extractor reads at most this many messages per pass, so the watermark
  # may only advance over a batch of the same size — anything past it stays
  # unread and must be picked up by the next pass.
  @max_text_length 500_000

  @spec process_session(String.t()) ::
          [:ok | {:error, term()}]
          | {:error, term()}
          | {:error, :partial, [Fact.t()], [{map(), Ecto.Changeset.t()}]}
  def process_session(session_id) do
    with {:ok, scope} <- Scopes.get_by_session(session_id),
         messages = messages_batch(session_id, scope.last_extracted_message_id, @max_text_length),
         {:ok, facts} <- Extractor.extract_facts(messages, ""),
         old_facts = Facts.facts_for(scope.id),
         facts = Reconciler.reconcile_facts(facts, old_facts, scope.id),
         {:ok, _scope} <- bump_scope_watermark(messages, scope) do
      facts = Embeddings.embed_facts(facts)
      processed_messages = Enum.count(messages)
      fact_count = Enum.count(facts)

      if processed_messages > 0 do
        Logger.info("#{session_id}: #{fact_count} facts from #{processed_messages} messages")
      end
    end
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  @spec messages_batch(String.t(), integer(), integer()) :: [Message.t()]
  defp messages_batch(session_id, from_id, max_length) do
    session_id
    |> Messages.get_session(from: from_id)
    |> Enum.reduce_while({0, []}, fn message, {charcount, messages} ->
      if charcount > max_length do
        {:halt, {charcount, messages}}
      else
        message_length = String.length(message.content)

        {:cont, {charcount + message_length, [message | messages]}}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  @spec bump_scope_watermark([Message.t()], Scope.t()) ::
          {:ok, Scope.t()} | {:error, Ecto.Changeset.t()}
  defp bump_scope_watermark([], scope), do: {:ok, scope}

  defp bump_scope_watermark(messages, scope) do
    latest_message_id = messages |> List.last() |> Map.get(:id)

    Scopes.set_last_extracted(scope, latest_message_id)
  end
end
