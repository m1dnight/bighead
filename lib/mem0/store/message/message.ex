defmodule Mem0.Store.Message do
  use Ecto.Schema

  import Ecto.Changeset

  alias Mem0.Store.Scope
  alias Pgvector.Ecto.Vector

  @type t :: %__MODULE__{}

  @roles ~w(user assistant system)

  schema "messages" do
    belongs_to :scope, Scope

    field :role, :string
    field :content, :string
    field :timestamp, :utc_datetime_usec
    field :embedding_768, Vector

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(message \\ %__MODULE__{}, attrs) do
    message
    |> cast(attrs, [:scope_id, :role, :content, :timestamp, :embedding_768])
    |> validate_required([:scope_id, :role, :content, :timestamp])
    |> validate_inclusion(:role, @roles)
    |> foreign_key_constraint(:scope_id)
  end
end
