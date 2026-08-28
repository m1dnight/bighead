defmodule Mem0.Processor do
  @moduledoc """
  Concerns itself with making sure all sessions in the database are properly extracted.
  """

  alias Mem0.Embeddings
  alias Mem0.Extractor
  alias Mem0.Store.Fact
  alias Mem0.Store.Facts
  alias Mem0.Store.Message
  alias Mem0.Store.Messages
  alias Mem0.Store.Scope
  alias Mem0.Store.Scopes

  # The extractor reads at most this many messages per pass, so the watermark
  # may only advance over a batch of the same size — anything past it stays
  # unread and must be picked up by the next pass.
  @batch_size 50

  @spec process_session(String.t()) ::
          [:ok | {:error, term()}]
          | {:error, term()}
          | {:error, :partial, [Fact.t()], [{map(), Ecto.Changeset.t()}]}
  def process_session(session_id) do
    with {:ok, scope} <- Scopes.get_by_session(session_id),
         messages = fetch_batch(session_id, scope),
         {:ok, facts} <- Extractor.extract_facts(messages, "", scope.id),
         {:ok, stored} <- store_facts(facts, scope.id),
         {:ok, _scope} <- bump_scope_watermark(messages, scope) do
      Embeddings.embed_facts(stored)
    end
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # defp reconcile_facts(facts, scope_id) do
  #   with {:ok, known_facts} <- Facts.facts_for(scope_id) do

  # end
  @spec fetch_batch(String.t(), Scope.t()) :: [Message.t()]
  defp fetch_batch(session_id, scope) do
    session_id
    |> Messages.get_session(from: scope.last_extracted_message_id)
    |> Enum.take(@batch_size)
  end

  @spec store_facts([String.t()], integer()) ::
          {:ok, [Fact.t()]} | {:error, :partial, [Fact.t()], [{map(), Ecto.Changeset.t()}]}
  defp store_facts(facts, scope_id) do
    facts
    |> Enum.reduce_while({[], []}, fn fact, {facts, errors} ->
      attrs = %{fact: fact, scope_id: scope_id}

      case Facts.create(attrs) do
        {:ok, fact} ->
          {:cont, {[fact | facts], errors}}

        {:error, err} ->
          {:halt, {facts, [{attrs, err} | errors]}}
      end
    end)
    |> case do
      {facts, []} ->
        {:ok, facts}

      {facts, errs} ->
        {:error, :partial, facts, errs}
    end
  end

  @spec bump_scope_watermark([Message.t()], Scope.t()) ::
          {:ok, Scope.t()} | {:error, Ecto.Changeset.t()}
  defp bump_scope_watermark([], scope), do: {:ok, scope}

  defp bump_scope_watermark(messages, scope) do
    latest_message_id = messages |> List.last() |> Map.get(:id)

    Scopes.set_last_extracted(scope, latest_message_id)
  end
end
