defmodule Mem0.Messages.Row do
  @moduledoc """
  The `messages` table, and the translation between it and
  `Mem0.Core.Message`.

  This is a table shape, not a second domain type. `Mem0.Messages` is the only
  module allowed to know it exists, which is what keeps the Ecto dependency
  from spreading: everything else in the system passes `Mem0.Core.Message`
  structs around and never learns there is a row behind them.

  Roles cross the boundary through two explicit maps rather than
  `String.to_atom/1` — user data never mints an atom — and through
  `Map.fetch!/2` on both directions, so a fourth role fails loudly here instead
  of writing a `nil` into the column or reading one back out.
  """

  use Ecto.Schema

  alias Mem0.Core.Message
  alias Mem0.Core.Scope
  alias Pgvector.Ecto.Vector

  @type t :: %__MODULE__{
          id: Message.id(),
          user_id: String.t(),
          app_id: String.t() | nil,
          run_id: String.t() | nil,
          role: String.t(),
          content: String.t(),
          said_at: DateTime.t(),
          seq: non_neg_integer(),
          embedding: Pgvector.t() | nil,
          inserted_at: DateTime.t()
        }

  @role_to_column %{user: "user", assistant: "assistant", system: "system"}
  @column_to_role %{"user" => :user, "assistant" => :assistant, "system" => :system}

  @primary_key {:id, :string, autogenerate: false}
  schema "messages" do
    field :user_id, :string
    field :app_id, :string
    field :run_id, :string
    field :role, :string
    field :content, :string
    field :said_at, :utc_datetime_usec
    field :seq, :integer
    field :embedding, Vector

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  A message as the plain map `Ecto.Repo.insert_all/3` takes.

  A map rather than a `%__MODULE__{}` because that is what `insert_all/3`
  wants, and `inserted_at` is an argument rather than a clock read here because
  `insert_all/3` does not fill timestamps for you — one instant stamps a whole
  batch.

  `embedding` is simply absent from the map. That is what leaves the column
  NULL, which is the honest value for "not computed": a zero placeholder would
  make pgvector's cosine distance NaN, and NaN sorts ahead of every real
  distance.
  """
  @spec from_message(Message.t(), DateTime.t()) :: map()
  def from_message(%Message{} = message, %DateTime{} = inserted_at) do
    %{
      id: message.id,
      user_id: message.scope.user_id,
      app_id: message.scope.app_id,
      run_id: message.scope.run_id,
      role: Map.fetch!(@role_to_column, message.role),
      content: message.content,
      said_at: message.said_at,
      seq: message.seq,
      inserted_at: inserted_at
    }
  end

  @doc """
  A row as the `Mem0.Core.Message` it came from.

  The nested scope is rebuilt with `Scope.new/1`, which is idempotent over its
  own output — so a blank that normalised to `nil` on the way in stays `nil` on
  the way out rather than round-tripping into something new.
  """
  @spec to_message(t()) :: Message.t()
  def to_message(%__MODULE__{} = row) do
    Message.new(
      id: row.id,
      scope: Scope.new(user_id: row.user_id, app_id: row.app_id, run_id: row.run_id),
      role: Map.fetch!(@column_to_role, row.role),
      content: row.content,
      said_at: row.said_at,
      seq: row.seq
    )
  end
end
