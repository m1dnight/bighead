defmodule Bighead.RecallerTest do
  @moduledoc """
  The recaller: embed a prompt, keep the closest facts above the floor.
  """
  use Bighead.DataCase, async: true

  alias Bighead.Embedder
  alias Bighead.Recaller
  alias Bighead.Store.Facts
  alias Bighead.Store.Scopes

  setup do
    Embedder.Stub.start!()
    {:ok, scope} = Scopes.create(%{user: "u", project: "/code/widget", session: "session-1"})
    %{scope: scope}
  end

  test "returns facts above the floor, most similar first", %{scope: scope} do
    {:ok, same} = embedded_fact(scope, "same direction", basis(0))
    {:ok, close} = embedded_fact(scope, "close by", tilted(0, 1, 0.8))
    {:ok, _orthogonal} = embedded_fact(scope, "orthogonal", basis(1))

    Embedder.Stub.set({:ok, [basis(0)]})

    assert {:ok, [first, second]} = Recaller.recall("anything")
    assert first.id == same.id
    assert second.id == close.id
  end

  test "skips facts that have no embedding yet", %{scope: scope} do
    {:ok, _unembedded} = Facts.create(%{fact: "not embedded yet", scope_id: scope.id})

    Embedder.Stub.set({:ok, [basis(0)]})

    assert {:ok, []} = Recaller.recall("anything")
  end

  test "respects :limit", %{scope: scope} do
    {:ok, same} = embedded_fact(scope, "same direction", basis(0))
    {:ok, _close} = embedded_fact(scope, "close by", tilted(0, 1, 0.8))

    Embedder.Stub.set({:ok, [basis(0)]})

    assert {:ok, [only]} = Recaller.recall("anything", limit: 1)
    assert only.id == same.id
  end

  test "a stricter floor drops the merely close", %{scope: scope} do
    {:ok, same} = embedded_fact(scope, "same direction", basis(0))
    {:ok, _close} = embedded_fact(scope, "close by", tilted(0, 1, 0.8))

    Embedder.Stub.set({:ok, [basis(0)]})

    assert {:ok, [only]} = Recaller.recall("anything", min_similarity: 0.99)
    assert only.id == same.id
  end

  test "restricts to :kind", %{scope: scope} do
    {:ok, _fact} = embedded_fact(scope, "a fact", basis(0))
    {:ok, guideline} = embedded_fact(scope, "a guideline", basis(0), :guideline)

    Embedder.Stub.set({:ok, [basis(0)]})

    assert {:ok, [only]} = Recaller.recall("anything", kind: :guideline)
    assert only.id == guideline.id
  end

  test "an embedder failure is reported, not swallowed" do
    Embedder.Stub.set({:error, {:transport_error, :econnrefused}})

    assert {:error, :failed_to_embed_prompt} = Recaller.recall("anything")
  end

  defp embedded_fact(scope, text, embedding, kind \\ :fact) do
    {:ok, fact} = Facts.create(%{fact: text, scope_id: scope.id, kind: kind})
    Facts.update(fact, %{embedding_768: embedding})
  end

  # The i-th standard basis vector of the embedding space.
  defp basis(i) do
    0.0 |> List.duplicate(768) |> List.replace_at(i, 1.0)
  end

  # A unit vector leaning towards basis `i`: cosine similarity with `basis(i)`
  # is exactly `weight`.
  defp tilted(i, j, weight) do
    0.0
    |> List.duplicate(768)
    |> List.replace_at(i, weight)
    |> List.replace_at(j, :math.sqrt(1.0 - weight * weight))
  end
end
