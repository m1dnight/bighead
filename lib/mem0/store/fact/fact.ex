defmodule Mem0.Store.Fact do
  use Ecto.Schema

  import Ecto.Changeset

  alias Mem0.Store.Scope
  alias Pgvector.Ecto.Vector

  @type t :: %__MODULE__{}

  schema "facts" do
    belongs_to :scope, Scope

    field :fact, :string
    field :embedding_768, Vector

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(fact \\ %__MODULE__{}, attrs) do
    fact
    |> cast(attrs, [:scope_id, :fact, :embedding_768])
    |> validate_required([:scope_id, :fact])
    |> foreign_key_constraint(:scope_id)
  end
end
