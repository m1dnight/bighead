defmodule Mem0.Core.Prompt do
  @moduledoc """
  A prompt is a triplet that is being fed into the extractor to extract facts.
  Facts are not yet memories, but rather candidates for storage.


  To extract facts, the function `Φ(P)` needs a prompt `P`.

  A prompt contains a summary, a list of recent messages, and a new message pair.

  `P = (S, {m_{t-m}..m_{t-2}}, m_{t-1}, m_t)`

  `summary` is optional because at the head of a new conversation there is no
  `S` yet.
  """

  use TypedStruct

  alias Mem0.Core.Message
  alias Mem0.Core.Scope
  alias Mem0.Core.Summary

  @typedoc "The new exchange `(m_{t-1}, m_t)` facts may be drawn from."
  @type pair :: {Message.t(), Message.t()}

  typedstruct enforce: true do
    field :scope, Scope.t()
    field :summary, Summary.t(), enforce: false
    field :recent, [Message.t()]
    field :pair, pair()
    field :at, DateTime.t()
  end

  @doc """
  Builds an extraction prompt. `summary` defaults to `nil`; everything else is
  required.
  """
  @spec new(keyword()) :: t()
  def new(fields) do
    fields
    |> Keyword.put_new(:summary, nil)
    |> then(&struct!(__MODULE__, &1))
  end
end
