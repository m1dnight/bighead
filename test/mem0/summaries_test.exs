defmodule Mem0.SummariesTest do
  @moduledoc """
  Put-then-latest is the phase. Everything else here is a guard on it: that
  latest follows the watermark rather than insertion order, that the scope is
  matched exactly with its `nil`s, and that the text survives the round trip
  byte for byte.
  """

  use Mem0.DataCase, async: true
  use Mem0.CoreFixtures

  alias Mem0.Summaries

  # Nonzero in every position, so a column that truncated to seconds or to
  # milliseconds would show up as an inequality rather than as a coincidence.
  @generated_at DateTime.add(at(0), 1_123_456, :microsecond)

  describe "put/1 and latest/1" do
    test "a summary reads back as the summary that went in" do
      scope = scope()

      sent =
        summary(
          scope: scope,
          # Multi-line unicode, because the text column is the phase.
          text: "Préfère les tabs.\n\nTravaille sur mem0 — une mémoire pour agents.",
          generated_at: @generated_at,
          through_seq: 42
        )

      assert :ok = Summaries.put(sent)
      assert Summaries.latest(scope) == sent
    end

    test "microseconds on generated_at survive the round trip" do
      scope = scope()

      assert :ok = Summaries.put(summary(scope: scope, generated_at: @generated_at))
      assert %Summary{} = read_back = Summaries.latest(scope)
      assert read_back.generated_at == @generated_at
      assert read_back.generated_at.microsecond == {123_456, 6}
    end

    test "a scope nothing was stored for has no latest" do
      assert Summaries.latest(scope()) == nil
    end

    test "latest follows the highest through_seq, not the last row inserted" do
      scope = scope()

      assert :ok = Summaries.put(summary(scope: scope, text: "further along", through_seq: 9))
      assert :ok = Summaries.put(summary(scope: scope, text: "further behind", through_seq: 4))

      assert %Summary{text: "further along", through_seq: 9} = Summaries.latest(scope)
    end

    test "of two regenerations at the same watermark, the later row wins" do
      scope = scope()

      assert :ok = Summaries.put(summary(scope: scope, text: "first attempt", through_seq: 7))
      assert :ok = Summaries.put(summary(scope: scope, text: "second attempt", through_seq: 7))

      assert %Summary{text: "second attempt"} = Summaries.latest(scope)
    end

    test "a second run in the same app is invisible" do
      mine = scope(run_id: "session-1")
      theirs = scope(run_id: "session-2")

      assert :ok = Summaries.put(summary(scope: mine, text: "mine"))
      assert :ok = Summaries.put(summary(scope: theirs, text: "theirs"))

      assert %Summary{text: "mine"} = Summaries.latest(mine)
      assert %Summary{text: "theirs"} = Summaries.latest(theirs)
    end

    test "a scope with no app or run reads back with both still nil" do
      bare = scope(app_id: nil, run_id: nil)

      assert :ok = Summaries.put(summary(scope: bare))
      assert %Summary{} = read_back = Summaries.latest(bare)
      assert read_back.scope == bare
      assert {nil, nil} == {read_back.scope.app_id, read_back.scope.run_id}
    end

    test "a nil scope and a valued scope do not see each other" do
      bare = scope(run_id: nil)
      run = scope(run_id: "session-1")

      assert :ok = Summaries.put(summary(scope: run, text: "run-scoped"))

      assert Summaries.latest(bare) == nil

      assert :ok = Summaries.put(summary(scope: bare, text: "bare"))
      assert %Summary{text: "bare"} = Summaries.latest(bare)
      assert %Summary{text: "run-scoped"} = Summaries.latest(run)
    end
  end
end
