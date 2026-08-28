defmodule Mem0.Memories.Row do
  @moduledoc """
  The `memories` table, and the translation between it and `Mem0.Core.Memory`.

  This table holds all memories that are considered true. A fact becomes a
  memory as soon as it is inserted in this database table.
  """

  use Ecto.Schema

  alias Mem0.Core.Memory
  alias Mem0.Core.Scope
  alias Pgvector.Ecto.Vector

  @type t :: %__MODULE__{
          id: Memory.id(),
          user_id: String.t(),
          app_id: String.t() | nil,
          run_id: String.t() | nil,
          content: String.t(),
          embedding: Pgvector.t(),
          extracted_at: DateTime.t(),
          event_time: DateTime.t() | nil,
          source_message_ids: [String.t()],
          superseded_at: DateTime.t() | nil,
          superseded_by_id: Memory.id() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "memories" do
    field :user_id, :string
    field :app_id, :string
    field :run_id, :string
    field :content, :string
    field :embedding, Vector
    field :extracted_at, :utc_datetime_usec
    field :event_time, :utc_datetime_usec
    field :source_message_ids, {:array, :string}
    field :superseded_at, :utc_datetime_usec
    field :superseded_by_id, Ecto.UUID
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @doc """
  A memory as an insertable row: the struct plus the vector it does not hold.
  """
  @spec from_memory(Memory.t(), [float()]) :: t()
  def from_memory(%Memory{} = memory, embedding) when is_list(embedding) do
    %__MODULE__{
      id: memory.id,
      user_id: memory.scope.user_id,
      app_id: memory.scope.app_id,
      run_id: memory.scope.run_id,
      content: memory.content,
      embedding: Pgvector.new(embedding),
      extracted_at: memory.extracted_at,
      event_time: memory.event_time,
      source_message_ids: memory.source_message_ids,
      created_at: memory.created_at,
      updated_at: memory.updated_at
    }
  end

  @doc """
  A row as the `Mem0.Core.Memory` it holds, dropping `embedding` and the
  supersession columns on the floor.

  The nested scope is rebuilt with `Scope.new/1`, which is idempotent over its
  own output — so a blank that normalised to `nil` on the way in stays `nil`
  on the way out rather than round-tripping into something new.
  """
  @spec to_memory(t()) :: Memory.t()
  def to_memory(%__MODULE__{} = row) do
    Memory.new(
      id: row.id,
      scope: Scope.new(user_id: row.user_id, app_id: row.app_id, run_id: row.run_id),
      content: row.content,
      extracted_at: row.extracted_at,
      event_time: row.event_time,
      source_message_ids: row.source_message_ids,
      created_at: row.created_at,
      updated_at: row.updated_at
    )
  end
end
