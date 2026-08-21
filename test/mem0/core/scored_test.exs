defmodule Mem0.Core.ScoredTest do
  @moduledoc """
  `rank/1` exists because `{score, struct}` does not sort usefully on its own —
  these tests are the evidence for that claim.
  """
  use ExUnit.Case, async: true
  use Mem0.CoreFixtures

  describe "rank/1" do
    test "puts the highest score first" do
      candidates = [{0.31, memory(id: "c")}, {0.91, memory(id: "a")}, {0.55, memory(id: "b")}]

      assert ["a", "b", "c"] = candidates |> Scored.rank() |> Enum.map(&elem(&1, 1).id)
    end

    test "is stable on ties" do
      candidates = [{0.5, memory(id: "first")}, {0.5, memory(id: "second")}]

      assert ["first", "second"] = candidates |> Scored.rank() |> Enum.map(&elem(&1, 1).id)
    end

    test "does what plain term order does not" do
      candidates = [{0.31, memory(id: "c")}, {0.91, memory(id: "a")}]

      refute Enum.sort(candidates) == Scored.rank(candidates)
    end

    test "handles an empty candidate set" do
      assert [] == Scored.rank([])
    end
  end

  describe "above/2" do
    test "keeps candidates at or above the threshold" do
      candidates = [{0.91, memory(id: "a")}, {0.70, memory(id: "b")}, {0.69, memory(id: "c")}]

      assert ["a", "b"] =
               candidates |> Scored.above(0.70) |> Enum.map(&elem(&1, 1).id)
    end

    test "preserves the order it was given" do
      candidates = [{0.70, memory(id: "b")}, {0.91, memory(id: "a")}]

      assert ["b", "a"] = candidates |> Scored.above(0.5) |> Enum.map(&elem(&1, 1).id)
    end
  end
end
