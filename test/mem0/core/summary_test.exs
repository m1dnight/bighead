defmodule Mem0.Core.SummaryTest do
  @moduledoc "The refresh cadence is undecided; that it is one pure comparison is not."
  use ExUnit.Case, async: true
  use Mem0.CoreFixtures

  describe "stale?/3" do
    test "is fresh while the head is within max_lag" do
      refute Summary.stale?(summary(through_seq: 4), 6, 2)
    end

    test "goes stale one message past max_lag" do
      assert Summary.stale?(summary(through_seq: 4), 7, 2)
    end

    test "is never stale when level with the head" do
      refute Summary.stale?(summary(through_seq: 4), 4, 0)
    end

    test "is never stale when the head is somehow behind it" do
      refute Summary.stale?(summary(through_seq: 9), 4, 0)
    end
  end

  describe "stale?/2" do
    test "falls back to the default lag" do
      refute Summary.stale?(summary(through_seq: 0), 10)
      assert Summary.stale?(summary(through_seq: 0), 11)
    end
  end
end
