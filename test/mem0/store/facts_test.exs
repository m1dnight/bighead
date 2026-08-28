defmodule Mem0.Store.FactsTest do
  @moduledoc """
  The facts context: dedup on `(scope, fact)`, the lifecycle of a fact, and
  similarity search over the embedded ones.
  """
  use Mem0.DataCase, async: true

  alias Mem0.Store.Facts
  alias Mem0.Store.Scopes

  setup do
    {:ok, scope} = Scopes.create(%{user: "u", project: "/code/widget", session: "session-1"})
    %{scope: scope}
  end

  describe "create/1" do
    test "inserts a fact with no embedding yet", %{scope: scope} do
      assert {:ok, fact} = Facts.create(%{fact: "Prefers Elixir", scope_id: scope.id})
      assert fact.fact == "Prefers Elixir"
      assert fact.embedding_768 == nil
    end

    test "the identical fact in the same scope lands on the same row", %{scope: scope} do
      assert {:ok, first} = Facts.create(%{fact: "Prefers Elixir", scope_id: scope.id})
      assert {:ok, second} = Facts.create(%{fact: "Prefers Elixir", scope_id: scope.id})

      assert second.id == first.id
      assert [_only_one] = Facts.list()
    end

    test "a missing fact fails validation", %{scope: scope} do
      assert {:error, changeset} = Facts.create(%{scope_id: scope.id})
      assert %{fact: ["can't be blank"]} = errors_on(changeset)
    end

    test "a fact cannot point at a scope that does not exist", %{scope: scope} do
      assert {:error, changeset} = Facts.create(%{fact: "x", scope_id: scope.id + 1})
      assert %{scope_id: ["does not exist"]} = errors_on(changeset)
    end
  end

  describe "list_by_scope/1" do
    test "returns only the scope's facts, oldest first", %{scope: scope} do
      {:ok, other} = Scopes.create(%{user: "u", project: "/w", session: "session-2"})

      {:ok, first} = Facts.create(%{fact: "first", scope_id: scope.id})
      {:ok, second} = Facts.create(%{fact: "second", scope_id: scope.id})
      {:ok, _elsewhere} = Facts.create(%{fact: "elsewhere", scope_id: other.id})

      assert [%{id: a}, %{id: b}] = Facts.list_by_scope(scope.id)
      assert {a, b} == {first.id, second.id}
    end

    test "a scope with nothing known yet is an empty list", %{scope: scope} do
      assert Facts.list_by_scope(scope.id) == []
    end
  end

  describe "get" do
    test "get/1 returns the fact or nil, get!/1 raises", %{scope: scope} do
      {:ok, fact} = Facts.create(%{fact: "x", scope_id: scope.id})

      assert Facts.get(fact.id).id == fact.id
      assert Facts.get(fact.id + 1) == nil
      assert_raise Ecto.NoResultsError, fn -> Facts.get!(fact.id + 1) end
    end
  end

  describe "update/2 and delete/1" do
    test "updates the stored fact", %{scope: scope} do
      {:ok, fact} = Facts.create(%{fact: "Uses Vim", scope_id: scope.id})

      assert {:ok, updated} = Facts.update(fact, %{fact: "Uses Neovim"})
      assert updated.fact == "Uses Neovim"
      assert Facts.get!(fact.id).fact == "Uses Neovim"
    end

    test "deletes, and deleting again reports staleness instead of raising", %{scope: scope} do
      {:ok, fact} = Facts.create(%{fact: "x", scope_id: scope.id})

      assert {:ok, _deleted} = Facts.delete(fact)
      assert Facts.get(fact.id) == nil
      assert {:error, changeset} = Facts.delete(fact)
      assert %{id: ["is stale"]} = errors_on(changeset)
    end
  end

  describe "most_similar/2" do
    test "orders by similarity and skips facts without an embedding", %{scope: scope} do
      {:ok, same} = embedded_fact(scope, "same direction", basis(0))
      {:ok, orthogonal} = embedded_fact(scope, "orthogonal", basis(1))
      {:ok, _unembedded} = Facts.create(%{fact: "not embedded yet", scope_id: scope.id})

      assert [{first_score, first}, {second_score, second}] =
               Facts.most_similar(basis(0), 10)

      assert first.id == same.id
      assert_in_delta first_score, 1.0, 1.0e-6
      assert second.id == orthogonal.id
      assert_in_delta second_score, 0.0, 1.0e-6
    end

    test "returns at most n facts, most similar first", %{scope: scope} do
      {:ok, _same} = embedded_fact(scope, "same direction", basis(0))
      {:ok, _orthogonal} = embedded_fact(scope, "orthogonal", basis(1))

      assert [{_score, %{fact: "same direction"}}] = Facts.most_similar(basis(0), 1)
    end
  end

  defp embedded_fact(scope, text, embedding) do
    {:ok, fact} = Facts.create(%{fact: text, scope_id: scope.id})
    Facts.update(fact, %{embedding_768: embedding})
  end

  # The i-th standard basis vector of the embedding space: identical vectors
  # have cosine similarity 1, different basis vectors 0.
  defp basis(i) do
    0.0 |> List.duplicate(768) |> List.replace_at(i, 1.0)
  end
end
