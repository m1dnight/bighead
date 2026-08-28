defmodule Mem0.ReconcilerTest do
  @moduledoc """
  Reconciliation through the stubbed LLM: each verdict the model can return,
  applied against stored facts, plus the replies that must not be trusted.
  """
  use Mem0.DataCase, async: true

  alias Mem0.LLM
  alias Mem0.Reconciler
  alias Mem0.Reconciler.Prompt
  alias Mem0.Store.Facts
  alias Mem0.Store.Scopes

  @candidate %{fact: "Prefers Neovim"}

  setup do
    LLM.Stub.start!()

    {:ok, scope} = Scopes.create(%{user: "u", project: "/w", session: "session-1"})
    {:ok, vim} = Facts.create(%{fact: "Uses Vim", scope_id: scope.id})
    {:ok, mem0} = Facts.create(%{fact: "Works on mem0", scope_id: scope.id})

    %{scope: scope, facts: [vim, mem0], vim: vim}
  end

  describe "reconcile_fact/3" do
    test "ADD stores the candidate as a new fact", %{scope: scope, facts: facts} do
      set_verdict("ADD", nil)

      assert {:ok, added} = Reconciler.reconcile_fact(@candidate, facts, scope.id)
      assert added.fact == "Prefers Neovim"
      assert Facts.get!(added.id).scope_id == scope.id
      assert length(Facts.list()) == 3
    end

    test "UPDATE rewrites the referenced fact with the candidate's text", %{
      scope: scope,
      facts: facts,
      vim: vim
    } do
      set_verdict("UPDATE", vim.id)

      assert {:ok, updated} = Reconciler.reconcile_fact(@candidate, facts, scope.id)
      assert updated.id == vim.id
      assert Facts.get!(vim.id).fact == "Prefers Neovim"
      assert length(Facts.list()) == 2
    end

    test "DELETE removes the referenced fact", %{scope: scope, facts: facts, vim: vim} do
      set_verdict("DELETE", vim.id)

      assert {:ok, deleted} = Reconciler.reconcile_fact(@candidate, facts, scope.id)
      assert deleted.id == vim.id
      assert Facts.get(vim.id) == nil
    end

    test "NOOP stores nothing", %{scope: scope, facts: facts} do
      set_verdict("NOOP", nil)

      assert {:ok, :noop} = Reconciler.reconcile_fact(@candidate, facts, scope.id)
      assert length(Facts.list()) == 2
    end

    test "a verdict about a fact that was not offered is an error", %{
      scope: scope,
      facts: facts,
      vim: vim
    } do
      unknown_id = vim.id + 1000

      set_verdict("DELETE", unknown_id)

      assert {:error, :fact_to_delete_not_found} =
               Reconciler.reconcile_fact(@candidate, facts, scope.id)

      set_verdict("UPDATE", unknown_id)

      assert {:error, :fact_to_update_not_found} =
               Reconciler.reconcile_fact(@candidate, facts, scope.id)
    end

    test "no stored facts to compare against is an error, and costs no call", %{scope: scope} do
      assert {:error, :no_facts_to_reconcile} =
               Reconciler.reconcile_fact(@candidate, [], scope.id)

      assert LLM.Stub.calls() == []
    end

    test "asks with the reconciliation prompt and the stored facts", %{
      scope: scope,
      facts: facts,
      vim: vim
    } do
      set_verdict("NOOP", nil)

      assert {:ok, :noop} = Reconciler.reconcile_fact(@candidate, facts, scope.id)

      assert [request] = LLM.Stub.calls()
      assert request.system == Prompt.system_prompt()
      assert request.schema["required"] == ["event", "id", "reason"]

      assert [%{role: :user, content: prompt}] = request.messages
      assert prompt =~ "#{vim.id}: Uses Vim"
      assert prompt =~ "Prefers Neovim"
    end

    test "a reply that is not JSON is an error", %{scope: scope, facts: facts} do
      LLM.Stub.set({:ok, LLM.Stub.response("shrug")})

      assert {:error, :invalid_json, "shrug"} =
               Reconciler.reconcile_fact(@candidate, facts, scope.id)
    end

    test "a decodable reply outside the four verdicts is an error", %{
      scope: scope,
      facts: facts
    } do
      LLM.Stub.set({:ok, LLM.Stub.response(Jason.encode!(%{"event" => "EXPLODE"}))})

      assert {:error, :invalid_response, %{"event" => "EXPLODE"}} =
               Reconciler.reconcile_fact(@candidate, facts, scope.id)
    end

    test "an LLM failure comes back as that failure", %{scope: scope, facts: facts} do
      LLM.Stub.set({:error, {:refusal, nil}})

      assert {:error, {:refusal, nil}} =
               Reconciler.reconcile_fact(@candidate, facts, scope.id)
    end
  end

  defp set_verdict(event, id) do
    reply = Jason.encode!(%{"event" => event, "id" => id, "reason" => "because"})
    LLM.Stub.set({:ok, LLM.Stub.response(reply)})
  end
end
