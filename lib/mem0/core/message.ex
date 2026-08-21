defmodule Mem0.Core.Message do
  @moduledoc """
  A single message present in a conversation.

  A message has a unique identifier, a scope in which it was said, a role of who
  said it, content, a timestamp, and a sequence number.

  Sequence numbers are orderings of messages within a single run. The user and
  app id do not matter for seq.
  """

  use TypedStruct

  alias Mem0.Core.Scope

  @typedoc """
  Opaque message identity. `String.t()` by convention rather than by `@opaque`;
  see `Mem0.Core.Memory.id/0` for why that trade-off was taken.
  """
  @type id :: String.t()

  @type role :: :user | :assistant | :system

  typedstruct enforce: true do
    field :id, id()
    field :scope, Scope.t()
    field :role, role()
    field :content, String.t()
    field :said_at, DateTime.t()
    field :seq, non_neg_integer()
  end

  @doc "Builds a message. Every field is required."
  @spec new(keyword()) :: t()
  def new(fields), do: struct!(__MODULE__, fields)
end
