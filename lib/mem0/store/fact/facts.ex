defmodule Mem0.Store.Facts do
  @moduledoc """
  Context module to retrieve/update/store facts in the database.
  """

  alias Mem0.Repo
  alias Mem0.Store.Fact

  @doc """
  Inserts a new fact.

  Returns `{:error, changeset}` when validation fails or `scope_id` does not
  reference an existing scope.

  We cannot do decent upserts here because the output of the llm is not
  deterministic. This means that we might insert the same fact twice.  However,
  we can catch the exactly identical facts anyway. To make sure we do not insert
  facts that are highly similar we will need to use the embeddings, but we
  generate those asynchronously. So there will be a garbage collection in a
  different way but not here.
  """
  @spec create(map()) :: {:ok, Fact.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Fact{}
    |> Fact.changeset(attrs)
    |> Repo.insert(
      # A no-op DO UPDATE rather than DO NOTHING: DO NOTHING returns no row
      # on conflict, so the existing fact's id would never come back.
      on_conflict: {:replace, [:fact]},
      conflict_target: {:unsafe_fragment, "(scope_id, md5(fact))"},
      returning: true
    )
  end

  @doc """
  Returns all facts.
  """
  @spec list() :: [Fact.t()]
  def list, do: Repo.all(Fact)

  @doc """
  Fetches a fact by id. Returns `nil` when it does not exist.
  """
  @spec get(integer()) :: Fact.t() | nil
  def get(id), do: Repo.get(Fact, id)

  @doc """
  Fetches a fact by id. Raises `Ecto.NoResultsError` when it does not exist.
  """
  @spec get!(integer()) :: Fact.t()
  def get!(id), do: Repo.get!(Fact, id)

  @doc """
  Updates an existing fact.
  """
  @spec update(Fact.t(), map()) :: {:ok, Fact.t()} | {:error, Ecto.Changeset.t()}
  def update(%Fact{} = fact, attrs) do
    fact
    |> Fact.changeset(attrs)
    |> Repo.update()
  end
end
