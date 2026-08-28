defmodule Mem0.Core.Memory do
  @moduledoc """
  A memory is something Mem0 has stored in memory. It's a fact that has been
  added to the data store.

  A memory has four timestamps:

   - `extracted_at` is the timestamp of the fact's extraction time.
   - `event_time` is the timestamp of the events the fact was extracted from.
   - `created_at` is the timestamp of when this memory was created.
   - `updated_at` is the timestamp when this memory was last updated. Memories
     can be updated by new facts.
  """

  use TypedStruct

  alias Mem0.Core.Fact
  alias Mem0.Core.Message
  alias Mem0.Core.Scope

  @typedoc """
  Opaque memory identity: comparable and printable, nothing more. The core needs
  no more than that, which is what keeps UUIDv7-versus-bigserial a question for
  whoever first needs a fact to survive a restart.

  Opaque **by convention, not by `@opaque`** — ids across the core are all
  `String.t()` and so mutually
  substitutable as far as Dialyzer is concerned. `@opaque` would catch a crossed
  id at the cost of an accessor in every module that touches one; not worth it
  at this size, and worth revisiting if a crossed id ever actually happens.
  """
  @type id :: String.t()

  typedstruct enforce: true do
    field :id, id()
    field :scope, Scope.t()
    field :content, String.t()
    field :extracted_at, DateTime.t()
    field :event_time, DateTime.t(), enforce: false
    field :source_message_ids, [Message.id()], default: []
    field :created_at, DateTime.t()
    field :updated_at, DateTime.t()
  end

  @doc """
  Builds a memory. `event_time` defaults to `nil` and `source_message_ids` to
  `[]`; the rest are required.
  """
  @spec new(keyword()) :: t()
  def new(fields) do
    fields
    |> Keyword.put_new(:event_time, nil)
    |> then(&struct!(__MODULE__, &1))
  end

  @doc """
  Identifies a candidate fact: the ADD arm of Algorithm 1.

  `at` is the utterance time supplied by the caller — the core never reads a
  clock — and `created_at` and `updated_at` are equal on the way in, as they
  should be for a memory nothing has revised yet.
  """
  @spec from_fact(id(), Fact.t(), DateTime.t()) :: t()
  def from_fact(id, %Fact{} = fact, %DateTime{} = at) do
    new(
      id: id,
      scope: fact.scope,
      content: fact.content,
      extracted_at: fact.extracted_at,
      event_time: fact.event_time,
      source_message_ids: fact.source_message_ids,
      created_at: at,
      updated_at: at
    )
  end

  @doc """
  Applies the UPDATE arm of Algorithm 1: the id survives, the content is
  replaced.

  `source_message_ids` **accumulates** rather than being replaced. After an
  update the content derives from both exchanges, and a provenance list naming
  only the most recent one cannot explain the memory it points at — which is the
  whole reason the field exists (notes §7 flags the missing link from a memory
  back to the messages that produced it). Existing ids keep their order and
  ids already present are not repeated.

  `created_at` is untouched; `updated_at` becomes `at`.
  """
  @spec apply_update(t(), Fact.t(), DateTime.t()) :: t()
  def apply_update(%__MODULE__{} = memory, %Fact{} = fact, %DateTime{} = at) do
    %{
      memory
      | content: fact.content,
        extracted_at: fact.extracted_at,
        event_time: fact.event_time,
        source_message_ids: Enum.uniq(memory.source_message_ids ++ fact.source_message_ids),
        updated_at: at
    }
  end
end
