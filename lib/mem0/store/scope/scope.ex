defmodule Mem0.Store.Scope do
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "scopes" do
    field :user, :string
    field :project, :string
    field :session, :string
    field :last_extracted_message_id, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(scope \\ %__MODULE__{}, attrs) do
    scope
    |> cast(attrs, [:user, :project, :session, :last_extracted_message_id])
    |> validate_required([:user])
    |> unique_constraint([:user, :project, :session])
    |> unique_constraint(:session)
  end
end
