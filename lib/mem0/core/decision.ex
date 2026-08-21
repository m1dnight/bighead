defmodule Mem0.Core.Decision do
  @moduledoc """
  A decision is a wrapper around an operation. It gives us a bit more
  information as to why a certain operation took place.

  The operation is what is supposed to happen to the memory store. If it's a
  delete or an update, the reason should be given. The reason will tell us
  exactly why this operation was deemed necessary by the LLM.

  For example, if we have the following memories:
   - 1: User eats carrots

  The fact "User is vegetarian" will result in an update of the fact. The reason
  here is that the fact generalizes the memory, and this will be stored in the
  reason.

  The considered ids are `[1]`.
  """

  use TypedStruct

  alias Mem0.Core.Memory
  alias Mem0.Core.MemoryOperation

  typedstruct enforce: true do
    field :operation, MemoryOperation.t()
    field :reason, String.t()
    field :considered_ids, [Memory.id()], default: []
    field :decided_at, DateTime.t()
  end

  @doc "Builds a decision. `considered_ids` defaults to `[]`."
  @spec new(keyword()) :: t()
  def new(fields), do: struct!(__MODULE__, fields)
end
