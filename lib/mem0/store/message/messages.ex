defmodule Mem0.Store.Messages do
  @moduledoc """
  Context module to retrieve/update/store messages in the database.
  """

  import Ecto.Query
  import Util

  alias Mem0.Repo
  alias Mem0.Store.Message
  alias Mem0.Store.Scope

  @doc """
  Inserts a new message, or returns the already-stored message with the same
  `(scope, timestamp, role, content)` combination.

  On conflict the existing row is left untouched — in particular a
  previously computed `embedding_768` survives re-ingesting the same
  transcript.

  Returns `{:error, changeset}` when validation fails or `scope_id` does not
  reference an existing scope.
  """
  @spec create(map()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert(
      # A no-op DO UPDATE rather than DO NOTHING: DO NOTHING returns no row
      # on conflict, so the existing message's id would never come back.
      on_conflict: {:replace, [:content]},
      conflict_target: {:unsafe_fragment, ~s/(scope_id, "timestamp", role, md5(content))/},
      returning: true
    )
  end

  def create_many(attrs_list) do
    Repo.transact(fn ->
      attrs_list
      |> traverse(fn attrs ->
        create(attrs)
      end)
    end)
  end

  @doc """
  Returns all messages.
  """
  @spec list() :: [Message.t()]
  def list, do: Repo.all(Message)

  @doc """
  Returns the conversation for the given session: every message whose scope
  carries that session, sorted by ascending id.

  ## Options

    * `:from` - only return messages with an id strictly greater than this one.
  """
  @spec get_session(String.t(), keyword()) :: [Message.t()]
  def get_session(session, opts \\ []) do
    Message
    |> join(:inner, [m], s in Scope, on: m.scope_id == s.id)
    |> where([m, s], s.session == ^session)
    |> after_id(Keyword.get(opts, :from))
    |> order_by([m], asc: m.id)
    |> Repo.all()
  end

  @spec after_id(Ecto.Query.t(), integer() | nil) :: Ecto.Query.t()
  defp after_id(query, nil), do: query
  defp after_id(query, id), do: where(query, [m], m.id > ^id)

  @doc """
  Returns every message whose scope carries the given project, across all of
  its sessions, sorted by timestamp with id as tiebreaker.
  """
  @spec get_project(String.t()) :: [Message.t()]
  def get_project(project) do
    Message
    |> join(:inner, [m], s in Scope, on: m.scope_id == s.id)
    |> where([m, s], s.project == ^project)
    |> order_by([m], asc: m.timestamp, asc: m.id)
    |> Repo.all()
  end

  @doc """
  Fetches a message by id. Returns `nil` when it does not exist.
  """
  @spec get(integer()) :: Message.t() | nil
  def get(id), do: Repo.get(Message, id)

  @doc """
  Fetches a message by id. Raises `Ecto.NoResultsError` when it does not exist.
  """
  @spec get!(integer()) :: Message.t()
  def get!(id), do: Repo.get!(Message, id)

  @doc """
  Updates an existing message.
  """
  @spec update(Message.t(), map()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def update(%Message{} = message, attrs) do
    message
    |> Message.changeset(attrs)
    |> Repo.update()
  end
end
