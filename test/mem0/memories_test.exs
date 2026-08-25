defmodule Mem0.MemoriesTest do
  @moduledoc """
  No LLM stub, no embedder stub — vectors are arguments, so these tests hand-
  build them. `unit_vector/1` makes cosine scores *exact*: orthogonal vectors
  score 0.0, identical ones 1.0, so search assertions are equalities, not
  tolerances.
  """

  use Mem0.DataCase, async: true
  use Mem0.CoreFixtures

  alias Mem0.Memories
  alias Mem0.Memories.Row

  @dimensions 768

  # Nonzero in every position, so a column that truncated to seconds or to
  # milliseconds would show up as an inequality rather than as a coincidence.
  @born_at DateTime.add(at(0), 1_123_456, :microsecond)

  describe "add/3 and active/1" do
    test "the same memory comes back, field for field" do
      fact = fact()

      assert {:ok, %Memory{} = memory} = Memories.add(fact, unit_vector(0), @born_at)
      assert is_binary(memory.id)
      assert memory == Memory.from_fact(memory.id, fact, @born_at)

      assert [read_back] = Memories.active(query())
      assert read_back == memory
      assert read_back.created_at.microsecond == {123_456, 6}
      assert read_back.event_time == nil
      assert read_back.source_message_ids == ["msg-2", "msg-3"]
    end

    test "active/1 and search/3 agree on the minted id" do
      assert {:ok, memory} = Memories.add(fact(), unit_vector(0), @born_at)

      assert [from_active] = Memories.active(query())
      assert [{1.0, from_search}] = Memories.search(query(), unit_vector(0), 10)
      assert from_active.id == memory.id
      assert from_search.id == memory.id
    end
  end

  describe "update/2" do
    test "content, updated_at and the vector change; created_at and the id do not" do
      assert {:ok, memory} = Memories.add(fact(), unit_vector(0), at(10))

      revision = fact(content: "User lives in Ghent", source_message_ids: ["msg-9"])
      updated = Memory.apply_update(memory, revision, at(20))

      assert :ok = Memories.update(updated, unit_vector(1))

      assert [read_back] = Memories.active(query())
      assert read_back == updated
      assert read_back.id == memory.id
      assert read_back.content == "User lives in Ghent"
      assert read_back.created_at == memory.created_at
      assert read_back.updated_at == at(20)

      # Findable by its new vector, and no longer by its old one.
      assert [{1.0, ^updated}] = Memories.search(query(), unit_vector(1), 10)
      assert [{+0.0, ^updated}] = Memories.search(query(), unit_vector(0), 10)
    end
  end

  describe "the not-found posture" do
    test "update/2 and supersede/3 on a missing or superseded id are all {:error, :not_found}" do
      assert {:ok, memory} = Memories.add(fact(), unit_vector(0), at(10))
      missing = Ecto.UUID.generate()

      assert {:error, :not_found} = Memories.update(%{memory | id: missing}, unit_vector(0))
      assert {:error, :not_found} = Memories.supersede(missing, at(20))

      assert :ok = Memories.supersede(memory.id, at(20))
      assert {:error, :not_found} = Memories.update(memory, unit_vector(0))
      assert {:error, :not_found} = Memories.supersede(memory.id, at(30))

      # The second supersede changed nothing: the first timestamp stands.
      row = Repo.get!(Row, memory.id)
      assert row.superseded_at == at(20)
    end
  end

  describe "supersede/3" do
    test "the memory vanishes from every read, and the row still exists" do
      assert {:ok, memory} = Memories.add(fact(), unit_vector(0), at(10))

      assert {:ok, replacement} =
               Memories.add(fact(content: "User moved"), unit_vector(1), at(20))

      assert :ok = Memories.supersede(memory.id, at(20), by: replacement.id)

      assert [^replacement] = Memories.active(query())
      assert [{_score, ^replacement}] = Memories.search(query(), unit_vector(0), 10)

      # The test module is allowed to know what the API rightly hides: the
      # row was marked, not removed.
      row = Repo.get!(Row, memory.id)
      assert row.superseded_at == at(20)
      assert row.superseded_by_id == replacement.id
      assert row.content == memory.content
    end
  end

  describe "search/3" do
    test "three orthogonal memories, queried with one of them, score exactly [1.0, 0.0, 0.0]" do
      assert {:ok, hit} = Memories.add(fact(content: "a"), unit_vector(0), at(10))
      assert {:ok, _miss} = Memories.add(fact(content: "b"), unit_vector(1), at(11))
      assert {:ok, _other_miss} = Memories.add(fact(content: "c"), unit_vector(2), at(12))

      results = Memories.search(query(), unit_vector(0), 10)

      assert [1.0, 0.0, 0.0] == Enum.map(results, &elem(&1, 0))
      assert [{1.0, ^hit} | _misses] = results
    end

    test "max_memories truncates the ranking" do
      assert {:ok, hit} = Memories.add(fact(content: "a"), unit_vector(0), at(10))
      assert {:ok, _miss} = Memories.add(fact(content: "b"), unit_vector(1), at(11))

      assert [{1.0, ^hit}] = Memories.search(query(), unit_vector(0), 1)
    end

    test "a superseded memory never appears" do
      assert {:ok, memory} = Memories.add(fact(), unit_vector(0), at(10))
      assert :ok = Memories.supersede(memory.id, at(20))

      assert [] == Memories.search(query(), unit_vector(0), 10)
    end

    test "another user's memories never appear, regardless of query breadth" do
      theirs = scope(user_id: "someone-else")
      assert {:ok, _memory} = Memories.add(fact(scope: theirs), unit_vector(0), at(10))

      assert [] == Memories.search(query(), unit_vector(0), 10)
    end
  end

  describe "ScopeQuery semantics" do
    test "a query naming an app narrows; a nil app_id broadens" do
      scope_a = scope(app_id: "app-a", run_id: nil)
      scope_b = scope(app_id: "app-b", run_id: nil)
      bare = scope(app_id: nil, run_id: nil)

      assert {:ok, in_a} = Memories.add(fact(scope: scope_a), unit_vector(0), at(10))
      assert {:ok, in_b} = Memories.add(fact(scope: scope_b), unit_vector(1), at(11))
      assert {:ok, in_none} = Memories.add(fact(scope: bare), unit_vector(2), at(12))

      assert [in_a] == Memories.active(query(app_id: "app-a"))
      assert [in_a, in_b, in_none] == Memories.active(query())
    end
  end

  describe "the error posture" do
    test "add/3 with the wrong vector width is an error, not a raise" do
      assert {:error, %Postgrex.Error{}} = Memories.add(fact(), [1.0, 0.0], at(10))
    end
  end

  # A read filter over the fixture user. With no overrides both optional
  # levels are nil, which broadens: every memory the fixtures write is in its
  # cover.
  defp query(overrides \\ []) do
    overrides
    |> Keyword.put_new(:user_id, "christophe")
    |> ScopeQuery.new()
  end

  # 768-wide, 1.0 at position `i`: mutually orthogonal, so cosine similarity
  # between any two of them is exactly 0.0 and against themselves exactly 1.0.
  defp unit_vector(i) when i >= 0 and i < @dimensions do
    for position <- 0..(@dimensions - 1), do: if(position == i, do: 1.0, else: 0.0)
  end
end
