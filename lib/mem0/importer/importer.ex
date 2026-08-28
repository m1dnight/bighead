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
  """
  @spec import_transcript(String.t(), module()) ::
          {:ok, [Message.t()]}
          | {:error, term()}
          | {:error, :partial, [Message.t()], [{map(), Ecto.Changeset.t()}]}
  def import_transcript(content, ingester) do
    with {:ok, scope, messages} <- Ingester.decode_transcript(content, ingester),
         {:ok, scope} <- Scopes.create(Map.put(scope, :user, "default")) do
      store_messages(messages, scope)
    end
  end

  @spec store_messages([map()], Scope.t()) ::
          {:ok, [Message.t()]}
          | {:error, :partial, [Message.t()], [{map(), Ecto.Changeset.t()}]}
  defp store_messages(messages, scope) do
    messages
    |> Enum.reduce_while({[], []}, fn attrs, {messages, errors} ->
      attrs = Map.put(attrs, :scope_id, scope.id)

      case Messages.create(attrs) do
        {:ok, message} ->
          {:cont, {[message | messages], errors}}

        {:error, err} ->
          {:halt, {messages, [{attrs, err} | errors]}}
      end
    end)
    |> case do
      {messages, []} ->
        {:ok, messages}

      {messages, errs} ->
        {:error, :partial, messages, errs}
    end
  end
end
