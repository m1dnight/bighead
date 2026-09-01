defmodule Mem0.Store.DiffsTest do
  @moduledoc """
  The diffs context: dedup on `(file, diff)` and reads per file.
  """
  use Mem0.DataCase, async: true

  alias Mem0.Store.Diffs

  @diff """
  @@ -1,2 +1,2 @@
  -def hello, do: :world
  +def hello, do: :mem0
  """

  describe "create/1" do
    test "inserts a diff" do
      assert {:ok, diff} = Diffs.create(%{file: "lib/foo.ex", diff: @diff})
      assert diff.file == "lib/foo.ex"
      assert diff.diff == @diff
    end

    test "the identical diff for the same file lands on the same row" do
      assert {:ok, first} = Diffs.create(%{file: "lib/foo.ex", diff: @diff})
      assert {:ok, second} = Diffs.create(%{file: "lib/foo.ex", diff: @diff})

      assert second.id == first.id
      assert [_only_one] = Diffs.list()
    end

    test "the identical diff for another file is its own row" do
      assert {:ok, first} = Diffs.create(%{file: "lib/foo.ex", diff: @diff})
      assert {:ok, second} = Diffs.create(%{file: "lib/bar.ex", diff: @diff})

      assert second.id != first.id
    end

    test "missing fields fail validation" do
      assert {:error, changeset} = Diffs.create(%{})

      assert %{file: ["can't be blank"], diff: ["can't be blank"]} =
               errors_on(changeset)
    end
  end

  describe "for_file/1" do
    test "returns only the file's diffs, oldest first" do
      {:ok, first} = Diffs.create(%{file: "lib/foo.ex", diff: "one"})
      {:ok, second} = Diffs.create(%{file: "lib/foo.ex", diff: "two"})
      {:ok, _elsewhere} = Diffs.create(%{file: "lib/bar.ex", diff: "three"})

      assert [%{id: a}, %{id: b}] = Diffs.for_file("lib/foo.ex")
      assert {a, b} == {first.id, second.id}
    end

    test "a file with nothing recorded yet is an empty list" do
      assert Diffs.for_file("lib/foo.ex") == []
    end
  end

  describe "get" do
    test "get/1 returns the diff or nil, get!/1 raises" do
      {:ok, diff} = Diffs.create(%{file: "lib/foo.ex", diff: @diff})

      assert Diffs.get(diff.id).id == diff.id
      assert Diffs.get(diff.id + 1) == nil
      assert_raise Ecto.NoResultsError, fn -> Diffs.get!(diff.id + 1) end
    end
  end
end
