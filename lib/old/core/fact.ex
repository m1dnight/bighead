defmodule Mem0.Core.Fact do
  @moduledoc """
  A fact is extracted from a prompt, and is considered a candidate for the
  memory.

  A fact in and of itself is not true. It has to be checked against what the
  memory holds, and will be classified later.
  """

  use TypedStruct

  alias Mem0.Core.Message
  alias Mem0.Core.Scope

  typedstruct enforce: true do
    field :content, String.t()
    field :scope, Scope.t()
    field :extracted_at, DateTime.t()
    field :event_time, DateTime.t(), enforce: false
    field :source_message_ids, [Message.id()], default: []
  end

  @doc """
  Builds a candidate fact. `event_time` defaults to `nil` and
  `source_message_ids` to `[]`; the rest are required.
  """
  @spec new(keyword()) :: t()
  def new(fields) do
    fields
    |> Keyword.put_new(:event_time, nil)
    |> then(&struct!(__MODULE__, &1))
  end
end
