defmodule Mem0.ExtractionStateTest do
  @moduledoc """
  The cursor is one mutable row per scope, and everything below is about the
  two properties that make that safe: exactly one row per scope — nil scopes
  included, which is the `nulls_distinct: false` proof — and a watermark that
  only ever moves forward.
  """

  use Mem0.DataCase, async: true
  use Mem0.CoreFixtures

  alias Mem0.ExtractionState
  alias Mem0.ExtractionState.Row

  describe "through_seq/1" do
    test "a scope never pulsed reads nil" do
      assert ExtractionState.through_seq(scope()) == nil
    end

    test "advance then read round-trips" do
      scope = scope()

      assert :ok = ExtractionState.advance(scope, 7, at(0))
      assert ExtractionState.through_seq(scope) == 7
    end

    test "two scopes differing only in run_id do not share a cursor" do
      :ok = ExtractionState.advance(scope(run_id: "session-1"), 7, at(0))

      assert ExtractionState.through_seq(scope(run_id: "session-2")) == nil
    end
  end

  describe "advance/3" do
    test "a bare {user, nil, nil} scope advanced twice holds one row" do
      scope = scope(app_id: nil, run_id: nil)

      assert :ok = ExtractionState.advance(scope, 3, at(0))
      assert :ok = ExtractionState.advance(scope, 5, at(1))

      # One row, not two: in a default unique index NULL ≠ NULL, so without
      # `nulls_distinct: false` the second advance would insert rather than
      # conflict and every read of this scope would be ambiguous.
      assert Repo.aggregate(Row, :count) == 1
      assert ExtractionState.through_seq(scope) == 5
    end

    test "advance to 10 then to 5 reads 10 — the watermark is monotonic" do
      scope = scope()

      assert :ok = ExtractionState.advance(scope, 10, at(0))
      assert :ok = ExtractionState.advance(scope, 5, at(1))

      assert ExtractionState.through_seq(scope) == 10
    end

    test "pulsed_at means last pulse, not furthest pulse" do
      scope = scope()

      :ok = ExtractionState.advance(scope, 10, at(0))
      :ok = ExtractionState.advance(scope, 5, at(1))

      assert %Row{pulsed_at: pulsed_at} = Repo.one!(Row)
      assert pulsed_at == at(1)
    end
  end
end
