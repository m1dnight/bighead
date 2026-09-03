defmodule Bighead.Importer do
  @moduledoc """
  The importer ingests whole transcript files at once.
  """

  alias Bighead.Ingester
  alias Bighead.Store.Message
  alias Bighead.Store.Messages
  alias Bighead.Store.Scope
  alias Bighead.Store.Scopes

  @doc """
  Given the content of transcript and an ingester, parses and stores all the
  messages from this transcript.
  """
  @spec import_transcript(String.t(), module()) :: {:ok, Scope.t(), [Message.t()]} | {:error, term()}
  def import_transcript(content, ingester) do
    with {:ok, scope, messages} <- Ingester.decode_transcript(content, ingester),
         {:ok, scope} <- Scopes.create(Map.put(scope, :user, "default")),
         {:ok, stored} <- store_messages(messages, scope) do
      {:ok, scope, stored}
    end
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # All-or-nothing: `create_many/1` runs in a transaction, so one bad message
  # rolls back the whole batch.
  @spec store_messages([map()], Scope.t()) :: {:ok, [Message.t()]} | {:error, Ecto.Changeset.t()}
  defp store_messages(messages, scope) do
    messages
    |> Enum.map(&Map.put(&1, :scope_id, scope.id))
    |> Messages.create_many()
  end
end
