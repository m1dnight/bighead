defmodule Mem0.Store.Messages do
  @moduledoc """
  Context module to retrieve/update/store messages in the database.
  """

  alias Mem0.Repo
  alias Mem0.Store.Message

  @doc """
  Inserts a new message.

  Returns `{:error, changeset}` when validation fails or `scope_id` does not
  reference an existing scope.
  """
  @spec create(map()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns all messages.
  """
  @spec list() :: [Message.t()]
  def list, do: Repo.all(Message)

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
