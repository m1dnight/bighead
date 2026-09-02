defmodule Mem0.Store.Diff do
  use Ecto.Schema

  import Ecto.Changeset

  alias Mem0.Store.Scope

  @type t :: %__MODULE__{}

  schema "diffs" do
    belongs_to :scope, Scope

    field :file, :string
    field :diff, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(diff \\ %__MODULE__{}, attrs) do
    diff
    |> cast(attrs, [:scope_id, :file, :diff])
    |> validate_required([:scope_id, :file, :diff])
    |> foreign_key_constraint(:scope_id)
  end
end
