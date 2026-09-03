defmodule BigheadWeb.RecallJSON do
  @moduledoc """
  Renders `BigheadWeb.RecallController` responses.
  """

  alias Bighead.Store.Fact

  @doc """
  Renders the recalled facts, most relevant first.
  """
  @spec create(%{facts: [Fact.t()]}) :: map()
  def create(%{facts: facts}) do
    %{facts: Enum.map(facts, fn fact -> %{id: fact.id, fact: fact.fact, kind: fact.kind} end)}
  end

  @doc """
  Renders a failure with the reason the controller gives it.
  """
  @spec error(%{message: String.t()}) :: map()
  def error(%{message: message}) do
    %{error: message}
  end
end
