defmodule Mem0.Processor do
  @moduledoc """
  Concerns itself with making sure all sessions in the database are properly extracted.
  """

  import Util

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

  @doc """
  Processes all stale sessions.
  """
  @spec process_sessions() :: {[{[Fact.t()], [Message.t()]}], [term()]}
  def process_sessions do
    Scopes.stale()
    |> partition_map(fn scope ->
      case process_session(scope.id) do
        {:ok, facts, messages} ->
          {:ok, {facts, messages}}

        err ->
          err
      end
    end)
  end

  @doc """
  Given a scope, extracts facts from the next batch of messages.
  """
  @spec process_session(integer()) :: {:ok, [Fact.t()], [Message.t()]} | {:error, term()}
  def process_session(scope_id) do
    with %Scope{} = scope <- Scopes.get(scope_id),
         messages = next_messages(scope, @max_text_length),
         # Extract facts from the messages.
         {:ok, facts} <- Extractor.extract_facts(messages, ""),
         :ok = log_extracted(scope, facts),
         # Fetch old facts, to reconcile.
         old_facts = Facts.facts_for(scope.id),
         # Reconcile the new facts with the known ones.
         facts = Reconciler.reconcile_facts(facts, old_facts, scope.id),
         # Embed the facts
         {:ok, facts} <- Embeddings.embed_facts(facts),
         # Bump the scope's watermark to remember where it stopped.
         {:ok, _scope} <- bump_scope_watermark(messages, scope) do
      {:ok, facts, messages}
    else
      # `Scopes.get/1` misses with `nil`; everything else already errors.
      nil -> {:error, :session_does_not_exist}
      err -> err
    end
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#
  # fetches the next message batch and makes sure the total content does not
  # exceed the given limit.
  @spec next_messages(Scope.t(), non_neg_integer()) :: [Message.t()]
  defp next_messages(scope, max_length) do
    Messages.get_session(scope.session, from: scope.last_extracted_message_id)
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

  # Console feedback for debugging: what the LLM pulled out of this batch,
  # before reconciliation decides what to do with it.
  @spec log_extracted(Scope.t(), [String.t()]) :: :ok
  defp log_extracted(_scope, []), do: :ok

  defp log_extracted(scope, facts) do
    Logger.error(
      "Extracted #{length(facts)} fact(s) from session #{scope.session}:\n" <>
        Enum.map_join(facts, "\n", &("  - " <> &1))
    )
  end

  @spec bump_scope_watermark([Message.t()], Scope.t()) ::
          {:ok, Scope.t()} | {:error, Ecto.Changeset.t()}
  defp bump_scope_watermark([], scope) do
    {:ok, scope}
  end

  defp bump_scope_watermark(messages, scope) do
    latest_message_id = messages |> List.last() |> Map.get(:id)

    Scopes.set_last_extracted(scope, latest_message_id)
  end
end
