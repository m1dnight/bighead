defmodule Bighead.EmbeddingsTest do
  @moduledoc """
  Backfilling embeddings through the stubbed embedder: only unembedded facts
  are sent, one per call, and a failure leaves its fact untouched.
  """
  use Bighead.DataCase, async: true

  alias Bighead.Embedder
  alias Bighead.Embeddings
  alias Bighead.Store.Facts
  alias Bighead.Store.Scopes

  setup do
    Embedder.Stub.start!()

    {:ok, scope} = Scopes.create(%{user: "u", project: "/w", session: "session-1"})
    %{scope: scope}
  end

  describe "embed_facts/1" do
    test "computes and stores embeddings for facts that have none", %{scope: scope} do
      facts = for text <- ["fact one", "fact two"], do: fact(scope, text)

      assert {:ok, [_one, _two]} = Embeddings.embed_facts(facts)

      for fact <- facts do
        refute Facts.get!(fact.id).embedding_768 == nil
      end

      assert Embedder.Stub.calls() == [["fact one"], ["fact two"]]
    end

    test "a fact that already has an embedding costs nothing", %{scope: scope} do
      embedded = fact(scope, "already done")
      {:ok, embedded} = Facts.update(embedded, %{embedding_768: List.duplicate(0.5, 768)})

      assert {:ok, []} = Embeddings.embed_facts([embedded])
      assert Embedder.Stub.calls() == []
    end

    test "an embedder failure surfaces and leaves the facts unembedded", %{scope: scope} do
      fact = fact(scope, "fact one")

      Embedder.Stub.set({:error, {:http_error, 500, "boom"}})

      assert {:error, :failed_to_embed_facts} = Embeddings.embed_facts([fact])
      assert Facts.get!(fact.id).embedding_768 == nil
    end
  end

  defp fact(scope, text) do
    {:ok, fact} = Facts.create(%{fact: text, scope_id: scope.id})
    fact
  end
end
