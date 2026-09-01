defmodule Mem0.Store.Diffs do
  @moduledoc """
  Context module to retrieve/update/store code diffs in the database.
  """

  import Ecto.Query

  alias Mem0.Repo
  alias Mem0.Store.Diff

  @doc """
  Inserts a new diff, or returns the already-stored diff with the same
  `(file, diff)` combination.
  """
  @spec create(map()) :: {:ok, Diff.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Diff{}
    |> Diff.changeset(attrs)
    |> Repo.insert(
      # A no-op DO UPDATE rather than DO NOTHING: DO NOTHING returns no row
      # on conflict, so the existing diff's id would never come back.
      on_conflict: {:replace, [:file]},
      conflict_target: {:unsafe_fragment, "(file, md5(diff))"},
      returning: true
    )
  end

  @doc """
  Returns all diffs.
  """
  @spec list() :: [Diff.t()]
  def list, do: Repo.all(Diff)

  @doc """
  Returns all diffs recorded for the given file, oldest first.
  """
  @spec for_file(String.t()) :: [Diff.t()]
  def for_file(file) do
    Diff
    |> where([d], d.file == ^file)
    |> order_by([d], asc: d.id)
    |> Repo.all()
  end

  @doc """
  Fetches a diff by id. Returns `nil` when it does not exist.
  """
  @spec get(integer()) :: Diff.t() | nil
  def get(id), do: Repo.get(Diff, id)

  @doc """
  Fetches a diff by id. Raises `Ecto.NoResultsError` when it does not exist.
  """
  @spec get!(integer()) :: Diff.t()
  def get!(id), do: Repo.get!(Diff, id)
end
