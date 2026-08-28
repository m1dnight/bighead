defmodule Mem0.Processor do
  @moduledoc """
  Concerns itself with making sure all sessions in the database are properly extracted.
  """

  alias Mem0.Embeddings
  alias Mem0.Extractor
  alias Mem0.Store.Messages
  alias Mem0.Store.Scopes

  def process_session(session_id) do
    with {:ok, scope} <- Scopes.get_by_session(session_id),
         messages = Messages.get_session(session_id, from: scope.last_extracted_message_id),
         {:ok, facts} <- Extractor.extract_facts(messages, "", scope.id) do
      Embeddings.embed_facts(facts)
    end
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#
end
