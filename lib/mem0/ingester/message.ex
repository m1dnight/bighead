defmodule Mem0.Ingester.Message do
  @moduledoc """
  A message is the shape into which all messages from all agents have to be put
  in order for them to go further into the Mem0 pipeline. A message contains all
  the information we want to ingest from the agents.
  """

  use TypedStruct

  @type role :: :user | :assistant

  typedstruct enforce: true do
    field :id, String.t() | nil, enforce: false
    field :role, role()
    field :content, String.t()
    field :timestamp, DateTime.t()
  end
end
