defmodule Bighead.Reconciler do
  @moduledoc """
  Reconciles newly extracted facts with the facts that are already in the
  database.

  This module makes sure that when we insert a fact, it does not contradict any
  existing facts.

  If there are contradictions they are reoconciled here.
  """
  alias Bighead.Reconciler.Prompt
  alias Bighead.Store.Fact
  alias Bighead.Store.Facts

  @typep operation ::
           {:delete, integer(), String.t()}
           | {:update, integer(), String.t()}
           | {:add, nil, String.t()}
           | {:noop, nil, String.t()}

  @response_schema %{
    "additionalProperties" => false,
    "properties" => %{
      "event" => %{"enum" => ["ADD", "UPDATE", "DELETE", "NOOP"], "type" => "string"},
      "id" => %{"type" => ["integer", "null"]},
      "reason" => %{"type" => "string"}
    },
    "required" => ["event", "id", "reason"],
    "type" => "object"
  }

  @doc """
  Reconciles `new_facts` against `old_facts` and stores the outcome in
  `scope_id`. Every fact this creates is of `kind`, so `old_facts` should be
  the scope's facts of that same kind.
  """
  @spec reconcile_facts([String.t()], [Fact.t()], integer(), :fact | :guideline) :: [Fact.t()]
  def reconcile_facts(new_facts, [], scope_id, kind) do
    new_facts
    |> Enum.map(fn new_fact ->
      {:ok, fact} = Facts.create(%{fact: new_fact, scope_id: scope_id, kind: kind})
      fact
    end)
  end

  def reconcile_facts(new_facts, old_facts, scope_id, kind) do
    new_facts
    |> Enum.map(&reconcile_fact(&1, old_facts))
    |> Enum.dedup_by(fn
      {fact, {op, nil, _reason}} -> {op, fact}
      {_fact, {op, id, _reason}} -> {op, id}
    end)
    |> Enum.reduce([], fn {fact, operation}, facts ->
      case update_fact(operation, fact, old_facts, scope_id, kind) do
        {:ok, :deleted} ->
          facts

        {:ok, :noop} ->
          facts

        {:ok, %Fact{} = fact} ->
          [fact | facts]
      end
    end)
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  @spec reconcile_fact(String.t(), [Fact.t()]) ::
          {String.t(), operation()}
          | {:error, :no_facts_to_reconcile | Bighead.LLM.reason()}
          | {:error, :invalid_response, map()}
          | {:error, :invalid_json, String.t()}
  defp reconcile_fact(fact, facts) do
    with {:ok, request} <- request(fact, facts),
         {:ok, response} <- Bighead.LLM.complete(request),
         {:ok, operation} <- decode_response(response) do
      {fact, operation}
    end
  end

  @spec update_fact(operation(), String.t(), [Fact.t()], integer(), :fact | :guideline) ::
          {:ok, Fact.t() | :noop | :deleted} | {:error, term()}
  defp update_fact({:delete, id, _reason}, _fact, facts, _scope_id, _kind) do
    case Enum.find(facts, &(&1.id == id)) do
      nil ->
        {:error, :fact_to_delete_not_found}

      fact ->
        {:ok, _} = Facts.delete(fact)
        {:ok, :deleted}
    end
  end

  defp update_fact({:update, id, _reason}, new_fact, facts, _scope_id, _kind) do
    case Enum.find(facts, &(&1.id == id)) do
      nil ->
        {:error, :fact_to_update_not_found}

      fact ->
        Facts.update(fact, %{fact: new_fact})
    end
  end

  defp update_fact({:add, _id, _reason}, new_fact, _facts, scope_id, kind) do
    Facts.create(%{fact: new_fact, scope_id: scope_id, kind: kind})
  end

  defp update_fact({:noop, _id, _reason}, _new_fact, _facts, _scope_id, _kind) do
    {:ok, :noop}
  end

  # generates the request to complete via the LLM.
  @spec request(String.t(), [Fact.t()]) ::
          {:ok, Bighead.LLM.request()} | {:error, :no_facts_to_reconcile}
  defp request(_fact, []) do
    {:error, :no_facts_to_reconcile}
  end

  defp request(fact, facts) do
    prompt = Prompt.render(fact: fact, facts: facts)

    {:ok,
     %{
       messages: [%{role: :user, content: prompt}],
       schema: @response_schema,
       system: Prompt.system_prompt()
     }}
  end

  @spec decode_response(Bighead.LLM.response()) ::
          {:ok, operation()}
          | {:error, :invalid_response, map()}
          | {:error, :invalid_json, String.t()}
  defp decode_response(%{content: json_str}) do
    case Jason.decode(json_str) do
      {:ok, %{"event" => "DELETE", "id" => id, "reason" => reason}} ->
        {:ok, {:delete, id, reason}}

      {:ok, %{"event" => "UPDATE", "id" => id, "reason" => reason}} ->
        {:ok, {:update, id, reason}}

      {:ok, %{"event" => "ADD", "reason" => reason}} ->
        {:ok, {:add, nil, reason}}

      {:ok, %{"event" => "NOOP", "reason" => reason}} ->
        {:ok, {:noop, nil, reason}}

      {:ok, other} ->
        {:error, :invalid_response, other}

      _ ->
        {:error, :invalid_json, json_str}
    end
  end
end
