defmodule Mem0.Store.Facts do
  @moduledoc """
  Context module to retrieve/update/store facts in the database.
  """

  import Ecto.Query
  import Pgvector.Ecto.Query

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
  Returns all facts known for the given scope, sorted by ascending id.

  Options:
   - `:kind` keeps only facts of that kind (`:fact` or `:guideline`); every
     kind by default
  """
  @spec facts_for(integer(), keyword()) :: [Fact.t()]
  def facts_for(scope_id, opts \\ []) do
    Fact
    |> where([f], f.scope_id == ^scope_id)
    |> filter_kind(opts[:kind])
    |> order_by([f], asc: f.id)
    |> Repo.all()
  end

  @doc """
  Returns all facts known for the given `(user, project)` pair across all of
  its scopes, sorted by ascending id.

  Options:
   - `:kind` keeps only facts of that kind (`:fact` or `:guideline`); every
     kind by default
  """
  @spec facts_for_project(String.t(), String.t(), keyword()) :: [Fact.t()]
  def facts_for_project(user, project, opts \\ []) do
    Fact
    |> join(:inner, [f], s in assoc(f, :scope))
    |> where([f, s], s.user == ^user and s.project == ^project)
    |> filter_kind(opts[:kind])
    |> order_by([f], asc: f.id)
    |> Repo.all()
  end

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
  Returns the `n` facts most similar to `embedding`, most similar first.

  Each entry is a `{similarity, fact}` tuple where similarity is
  `1 - cosine_distance`, so higher is closer. Facts whose embedding has not
  been computed yet are skipped. Thresholding is the caller's job.

  Options:
   - `:kind` keeps only facts of that kind (`:fact` or `:guideline`); every
     kind by default
  """
  @spec most_similar([float()], pos_integer(), keyword()) :: [{float(), Fact.t()}]
  def most_similar(embedding, n, opts \\ []) when is_list(embedding) and is_integer(n) and n > 0 do
    vector = Pgvector.new(embedding)

    Fact
    |> where([f], not is_nil(f.embedding_768))
    |> filter_kind(opts[:kind])
    |> order_by([f], asc: cosine_distance(f.embedding_768, ^vector))
    |> limit(^n)
    |> select([f], {cosine_distance(f.embedding_768, ^vector), f})
    |> Repo.all()
    |> Enum.map(fn {distance, fact} -> {1.0 - distance, fact} end)
  end

  @doc """
  Updates an existing fact.
  """
  @spec update(Fact.t(), map()) :: {:ok, Fact.t()} | {:error, Ecto.Changeset.t()}
  def update(%Fact{} = fact, attrs) do
    fact
    |> Fact.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an existing fact.

  Returns `{:error, changeset}` when the fact was already deleted (stale).
  """
  @spec delete(Fact.t()) :: {:ok, Fact.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Fact{} = fact) do
    Repo.delete(fact, stale_error_field: :id)
  end

  # Narrows a query to one kind of fact; no kind means every kind.
  @spec filter_kind(Ecto.Query.t(), :fact | :guideline | nil) :: Ecto.Query.t()
  defp filter_kind(query, nil), do: query
  defp filter_kind(query, kind), do: where(query, [f], f.kind == ^kind)
end
