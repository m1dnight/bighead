defmodule Mem0.Store.Scope do
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :string, autogenerate: false}
  schema "scopes" do
    field :user, :string
    field :project, :string
    field :session, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(scope \\ %__MODULE__{}, attrs) do
    scope
    |> cast(attrs, [:id, :user, :project, :session])
    |> validate_required([:id, :user])
    |> unique_constraint([:user, :project, :session])
  end
end
