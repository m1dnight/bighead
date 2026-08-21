defmodule Mem0.Core.Extraction do
  @moduledoc """
  An extraction (Ω) is a set of facts (ω) extracted from a prompt.

  An extraction is built by a prompt in a specific scope, and that scope's
  messages.
  """

  use TypedStruct

  alias Mem0.Core.Fact
  alias Mem0.Core.Message
  alias Mem0.Core.Scope

  typedstruct enforce: true do
    field :scope, Scope.t()
    field :prompt_at, DateTime.t()
    field :facts, [Fact.t()], default: []
    field :source_message_ids, [Message.id()], default: []
  end

  @doc "Builds an extraction. `facts` and `source_message_ids` default to `[]`."
  @spec new(keyword()) :: t()
  def new(fields), do: struct!(__MODULE__, fields)
end
