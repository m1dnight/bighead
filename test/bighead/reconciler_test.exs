defmodule Bighead.ReconcilerTest do
  @moduledoc """
  Reconciliation through the stubbed LLM: each verdict the model can return,
  applied against stored facts.
  """
  use Bighead.DataCase, async: true

  alias Bighead.LLM
  alias Bighead.Reconciler
  alias Bighead.Reconciler.Prompt
  alias Bighead.Store.Facts
  alias Bighead.Store.Scopes

  @candidate "Prefers Neovim"

  setup do
    LLM.Stub.start!()

    {:ok, scope} = Scopes.create(%{user: "u", project: "/w", session: "session-1"})
    {:ok, vim} = Facts.create(%{fact: "Uses Vim", scope_id: scope.id})
    {:ok, bighead} = Facts.create(%{fact: "Works on bighead", scope_id: scope.id})

    %{scope: scope, facts: [vim, bighead], vim: vim}
  end

  describe "reconcile_facts/4" do
    test "no stored facts stores every candidate, and costs no call", %{scope: scope} do
      assert [added] = Reconciler.reconcile_facts([@candidate], [], scope.id, :fact)
      assert added.fact == @candidate
      assert added.kind == :fact
      assert Facts.get!(added.id).scope_id == scope.id
      assert LLM.Stub.calls() == []
    end

    test "ADD stores the candidate as a new fact", %{scope: scope, facts: facts} do
      set_verdict("ADD", nil)

      assert [added] = Reconciler.reconcile_facts([@candidate], facts, scope.id, :fact)
      assert added.fact == @candidate
      assert Facts.get!(added.id).scope_id == scope.id
      assert length(Facts.list()) == 3
    end

    test "ADD stores the candidate with the given kind", %{scope: scope, facts: facts} do
      set_verdict("ADD", nil)

      assert [added] = Reconciler.reconcile_facts([@candidate], facts, scope.id, :guideline)
      assert added.kind == :guideline
    end

    test "UPDATE rewrites the referenced fact with the candidate's text", %{
      scope: scope,
      facts: facts,
      vim: vim
    } do
      set_verdict("UPDATE", vim.id)

      assert [updated] = Reconciler.reconcile_facts([@candidate], facts, scope.id, :fact)
      assert updated.id == vim.id
      assert Facts.get!(vim.id).fact == @candidate
      assert length(Facts.list()) == 2
    end

    test "DELETE removes the referenced fact", %{scope: scope, facts: facts, vim: vim} do
      set_verdict("DELETE", vim.id)

      assert [] = Reconciler.reconcile_facts([@candidate], facts, scope.id, :fact)
      assert Facts.get(vim.id) == nil
    end

    test "NOOP stores nothing", %{scope: scope, facts: facts} do
      set_verdict("NOOP", nil)

      assert [] = Reconciler.reconcile_facts([@candidate], facts, scope.id, :fact)
      assert length(Facts.list()) == 2
    end

    test "asks with the reconciliation prompt and the stored facts", %{
      scope: scope,
      facts: facts,
      vim: vim
    } do
      set_verdict("NOOP", nil)

      assert [] = Reconciler.reconcile_facts([@candidate], facts, scope.id, :fact)

      assert [request] = LLM.Stub.calls()
      assert request.system == Prompt.system_prompt()
      assert request.schema["required"] == ["event", "id", "reason"]

      assert [%{role: :user, content: prompt}] = request.messages
      assert prompt =~ "#{vim.id}: Uses Vim"
      assert prompt =~ @candidate
    end
  end

  defp set_verdict(event, id) do
    reply = Jason.encode!(%{"event" => event, "id" => id, "reason" => "because"})
    LLM.Stub.set({:ok, LLM.Stub.response(reply)})
  end
end
