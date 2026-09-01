defmodule Mem0.Importer do
  @moduledoc """
  The importer ingests whole transcript files at once.
  """

  alias Mem0.Ingester
  alias Mem0.Store.Message
  alias Mem0.Store.Messages
  alias Mem0.Store.Scope
  alias Mem0.Store.Scopes

  @doc """
  Given the content of transcript and an ingester, parses and stores all the
  messages from this transcript.

  Returns the scope alongside the stored messages so callers can hand the
  session on to `Mem0.Processor` without re-deriving it from the file.
  """
  @spec import_transcript(String.t(), module()) ::
          {:ok, Scope.t(), [Message.t()]}
          | {:error, term()}
          | {:error, :partial, [Message.t()], [{map(), Ecto.Changeset.t()}]}
  def import_transcript(content, ingester) do
    with {:ok, scope, messages} <- Ingester.decode_transcript(content, ingester),
         {:ok, scope} <- Scopes.create(Map.put(scope, :user, "default")),
         {:ok, stored} <- store_messages(messages, scope) do
      {:ok, scope, stored}
    end
  end

  @spec store_messages([map()], Scope.t()) ::
          {:ok, [Message.t()]}
          | {:error, :partial, [Message.t()], [{map(), Ecto.Changeset.t()}]}
  defp store_messages(messages, scope) do
    messages
    |> Enum.map(&Map.put(&1, :scope_id, scope.id))
    |> Messages.create_many()
    |> tap(&IO.inspect(&1, label: "create_many", limit: 10))
  end
end
