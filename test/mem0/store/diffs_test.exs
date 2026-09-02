defmodule Mem0.Store.DiffsTest do
  @moduledoc """
  The diffs context: dedup on `(file, diff)` and reads per file.
  """
  use Mem0.DataCase, async: true

  alias Mem0.Store.Diffs
  alias Mem0.Store.Scopes

  @diff """
  @@ -1,2 +1,2 @@
  -def hello, do: :world
  +def hello, do: :mem0
  """

  setup do
    {:ok, scope} = Scopes.create(%{user: "u", project: "/code/widget", session: "session-1"})
    %{scope: scope}
  end

  describe "create/1" do
    test "inserts a diff", %{scope: scope} do
      assert {:ok, diff} = Diffs.create(%{file: "lib/foo.ex", diff: @diff, scope_id: scope.id})
      assert diff.file == "lib/foo.ex"
      assert diff.diff == @diff
      assert diff.scope_id == scope.id
    end

    test "the identical diff for the same file lands on the same row", %{scope: scope} do
      attrs = %{file: "lib/foo.ex", diff: @diff, scope_id: scope.id}

      assert {:ok, first} = Diffs.create(attrs)
      assert {:ok, second} = Diffs.create(attrs)

      assert second.id == first.id
      assert [_only_one] = Diffs.list()
    end

    test "the identical diff for another file is its own row", %{scope: scope} do
      assert {:ok, first} = Diffs.create(%{file: "lib/foo.ex", diff: @diff, scope_id: scope.id})
      assert {:ok, second} = Diffs.create(%{file: "lib/bar.ex", diff: @diff, scope_id: scope.id})

      assert second.id != first.id
    end

    test "missing fields fail validation" do
      assert {:error, changeset} = Diffs.create(%{})

      assert %{
               file: ["can't be blank"],
               diff: ["can't be blank"],
               scope_id: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "a diff cannot point at a scope that does not exist", %{scope: scope} do
      assert {:error, changeset} =
               Diffs.create(%{file: "lib/foo.ex", diff: @diff, scope_id: scope.id + 1})

      assert %{scope_id: ["does not exist"]} = errors_on(changeset)
    end
  end

  describe "for_file/1" do
    test "returns only the file's diffs, oldest first", %{scope: scope} do
      {:ok, first} = Diffs.create(%{file: "lib/foo.ex", diff: "one", scope_id: scope.id})
      {:ok, second} = Diffs.create(%{file: "lib/foo.ex", diff: "two", scope_id: scope.id})
      {:ok, _elsewhere} = Diffs.create(%{file: "lib/bar.ex", diff: "three", scope_id: scope.id})

      assert [%{id: a}, %{id: b}] = Diffs.for_file("lib/foo.ex")
      assert {a, b} == {first.id, second.id}
    end

    test "a file with nothing recorded yet is an empty list" do
      assert Diffs.for_file("lib/foo.ex") == []
    end
  end

  describe "for_scope/2" do
    test "returns the scope's diffs oldest first, optionally past an id", %{scope: scope} do
      {:ok, other} = Scopes.create(%{user: "u", project: "/code/other", session: "session-2"})
      {:ok, first} = Diffs.create(%{file: "lib/foo.ex", diff: "one", scope_id: scope.id})
      {:ok, second} = Diffs.create(%{file: "lib/bar.ex", diff: "two", scope_id: scope.id})
      {:ok, _elsewhere} = Diffs.create(%{file: "lib/foo.ex", diff: "three", scope_id: other.id})

      assert [%{id: a}, %{id: b}] = Diffs.for_scope(scope.id)
      assert {a, b} == {first.id, second.id}
      assert [%{id: ^b}] = Diffs.for_scope(scope.id, from: first.id)
      assert Diffs.for_scope(scope.id, from: second.id) == []
    end
  end

  describe "get" do
    test "get/1 returns the diff or nil, get!/1 raises", %{scope: scope} do
      {:ok, diff} = Diffs.create(%{file: "lib/foo.ex", diff: @diff, scope_id: scope.id})

      assert Diffs.get(diff.id).id == diff.id
      assert Diffs.get(diff.id + 1) == nil
      assert_raise Ecto.NoResultsError, fn -> Diffs.get!(diff.id + 1) end
    end
  end
end
