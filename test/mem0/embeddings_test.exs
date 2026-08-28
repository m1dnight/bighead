defmodule Mem0.EmbeddingsTest do
  @moduledoc """
  Backfilling embeddings through the stubbed embedder: only unembedded facts
  are sent, in batches, and a failing batch leaves its facts untouched.
  """
  use Mem0.DataCase, async: true

  alias Mem0.Embedder
  alias Mem0.Embeddings
  alias Mem0.Store.Facts
  alias Mem0.Store.Scopes

  setup do
    Embedder.Stub.start!()

    {:ok, scope} = Scopes.create(%{user: "u", project: "/w", session: "session-1"})
    %{scope: scope}
  end

  describe "embed_facts/1" do
    test "computes and stores embeddings for facts that have none", %{scope: scope} do
      facts = for text <- ["fact one", "fact two"], do: fact(scope, text)

      assert [:ok] = Embeddings.embed_facts(facts)

      for fact <- facts do
        refute Facts.get!(fact.id).embedding_768 == nil
      end

      assert Embedder.Stub.calls() == [["fact one", "fact two"]]
    end

    test "a fact that already has an embedding costs nothing", %{scope: scope} do
      embedded = fact(scope, "already done")
      {:ok, embedded} = Facts.update(embedded, %{embedding_768: List.duplicate(0.5, 768)})

      assert [] = Embeddings.embed_facts([embedded])
      assert Embedder.Stub.calls() == []
    end

    test "facts are embedded five at a time", %{scope: scope} do
      facts = for n <- 1..6, do: fact(scope, "fact #{n}")

      assert [:ok, :ok] = Embeddings.embed_facts(facts)
      assert [first_batch, second_batch] = Embedder.Stub.calls()
      assert length(first_batch) == 5
      assert length(second_batch) == 1
    end

    test "an embedder failure surfaces and leaves the facts unembedded", %{scope: scope} do
      fact = fact(scope, "fact one")

      Embedder.Stub.set({:error, {:http_error, 500, "boom"}})

      assert [{:error, {:http_error, 500, "boom"}}] = Embeddings.embed_facts([fact])
      assert Facts.get!(fact.id).embedding_768 == nil
    end
  end

  defp fact(scope, text) do
    {:ok, fact} = Facts.create(%{fact: text, scope_id: scope.id})
    fact
  end
end
