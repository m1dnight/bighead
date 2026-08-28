defmodule Mem0.Store.Scopes do
  @moduledoc """
  Context module to retrieve/update/store scopes in the database.
  """

  alias Mem0.Repo
  alias Mem0.Store.Scope

  @doc """
  Inserts a new scope, or returns the already-stored scope with the same
  `(user, project, session)` combination.
  """
  @spec create(map()) :: {:ok, Scope.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Scope{}
    |> Scope.changeset(attrs)
    |> Repo.insert(
      # A no-op DO UPDATE rather than DO NOTHING: DO NOTHING returns no row
      # on conflict, so the existing scope's id would never come back.
      on_conflict: {:replace, [:user]},
      conflict_target: [:user, :project, :session],
      returning: true
    )
  end

  @doc """
  Returns all scopes.
  """
  @spec list() :: [Scope.t()]
  def list, do: Repo.all(Scope)

  @doc """
  Fetches a scope by id. Returns `nil` when it does not exist.
  """
  @spec get(integer()) :: Scope.t() | nil
  def get(id), do: Repo.get(Scope, id)

  @doc """
  Fetches a scope by id. Raises `Ecto.NoResultsError` when it does not exist.
  """
  @spec get!(integer()) :: Scope.t()
  def get!(id), do: Repo.get!(Scope, id)

  @doc """
  Fetches the scope for a session. Returns `nil` when it does not exist.

  Sessions are globally unique, so at most one scope can match.
  """
  @spec get_by_session(String.t()) :: {:ok, Scope.t()} | {:error, :session_does_not_exist}
  def get_by_session(session) do
    Repo.get_by(Scope, session: session)
    |> case do
      nil ->
        {:error, :session_does_not_exist}

      scope ->
        {:ok, scope}
    end
  end

  @doc """
  Sets the id of the last message facts have been extracted from.
  """
  @spec set_last_extracted(Scope.t(), integer()) ::
          {:ok, Scope.t()} | {:error, Ecto.Changeset.t()}
  def set_last_extracted(%Scope{} = scope, message_id) do
    update(scope, %{last_extracted_message_id: message_id})
  end

  @doc """
  Updates an existing scope.

  Returns `{:error, changeset}` when validation fails or the change would
  collide with another scope's `(user, project, session)` combination.
  """
  @spec update(Scope.t(), map()) :: {:ok, Scope.t()} | {:error, Ecto.Changeset.t()}
  def update(%Scope{} = scope, attrs) do
    scope
    |> Scope.changeset(attrs)
    |> Repo.update()
  end
end
