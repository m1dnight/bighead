defmodule Mem0.Reconciler do
  @moduledoc """
  Reconciles newly extracted facts with the facts that are already in the
  database.

  This module makes sure that when we insert a fact, it does not contradict any
  existing facts.

  If there are contradictions they are reoconciled here.
  """
  alias Mem0.Reconciler.Prompt
  alias Mem0.Store.Facts

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

  def reconcile_fact(fact, facts, scope_id) do
    with {:ok, request} <- request(fact, facts),
         {:ok, response} <- Mem0.LLM.complete(request),
         {:ok, op} <- decode_response(response) do
      update_fact(op, fact, facts, scope_id)
    end
  end


  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  defp update_fact({:delete, id, _reason}, _fact, facts, _scope_id) do
    case Enum.find(facts, &(&1.id == id)) do
      nil ->
        {:error, :fact_to_delete_not_found}

      fact ->
        Facts.delete(fact)
    end
  end

  defp update_fact({:update, id, _reason}, new_fact, facts, _scope_id) do
    case Enum.find(facts, &(&1.id == id)) do
      nil ->
        {:error, :fact_to_update_not_found}

      fact ->
        Facts.update(fact, %{fact: new_fact.fact})
    end
  end

  defp update_fact({:add, _reason}, new_fact, _facts, scope_id) do
    Facts.create(%{fact: new_fact.fact, scope_id: scope_id})
  end

  defp update_fact({:noop, _reason}, new_fact, _facts, scope_id) do
    {:ok, :noop}
  end

  # generates the request to complete via the LLM.
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

  defp decode_response(%{content: json_str}) do
    case Jason.decode(json_str) do
      {:ok, %{"event" => "DELETE", "id" => id, "reason" => reason}} ->
        {:ok, {:delete, id, reason}}

      {:ok, %{"event" => "UPDATE", "id" => id, "reason" => reason}} ->
        {:ok, {:update, id, reason}}

      {:ok, %{"event" => "ADD", "reason" => reason}} ->
        {:ok, {:add, reason}}

      {:ok, %{"event" => "NOOP", "reason" => reason}} ->
        {:ok, {:noop, reason}}

      {:ok, other} ->
        {:error, :invalid_response, other}

      _ ->
        {:error, :invalid_json, json_str}
    end
  end
end
