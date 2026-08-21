defmodule Mem0.Core.ScopeTest do
  @moduledoc """
  The write/read asymmetry is the whole reason `Scope` and `ScopeQuery` are two
  types, so these tests are mostly about what cannot be built.
  """
  use ExUnit.Case, async: true
  use Mem0.CoreFixtures

  alias Mem0.Core.Scope

  doctest Scope

  describe "new/1" do
    test "requires user_id" do
      assert_raise ArgumentError, fn -> Scope.new(app_id: "mem0") end
    end

    test "rejects a nil user_id, which struct!/2 alone would accept" do
      assert %Scope{} = struct!(Scope, user_id: nil)
      assert_raise ArgumentError, fn -> Scope.new(user_id: nil) end
    end

    test "rejects a blank user_id for the same reason" do
      assert_raise ArgumentError, fn -> Scope.new(user_id: "   ") end
    end

    test "defaults app_id and run_id to nil, meaning general" do
      assert %Scope{app_id: nil, run_id: nil} = Scope.new(user_id: "christophe")
    end

    test "trims ids and normalises a blank optional id to nil" do
      scope = Scope.new(user_id: " christophe ", app_id: "", run_id: "  ")

      assert %Scope{user_id: "christophe", app_id: nil, run_id: nil} = scope
    end

    test "normalisation is idempotent" do
      once = Scope.new(user_id: " christophe ", app_id: " mem0 ", run_id: "")

      assert once ==
               Scope.new(user_id: once.user_id, app_id: once.app_id, run_id: once.run_id)
    end
  end

  describe "covering/1" do
    test "widens from the exact run through the app to the user" do
      assert [run_rung, app_rung, user_rung] = Scope.covering(scope())

      assert %ScopeQuery{user_id: "christophe", app_id: "mem0", run_id: "session-1"} = run_rung
      assert %ScopeQuery{user_id: "christophe", app_id: "mem0", run_id: nil} = app_rung
      assert %ScopeQuery{user_id: "christophe", app_id: nil, run_id: nil} = user_rung
    end

    test "drops the run rung when there is no run to be exact about" do
      assert [app_rung, user_rung] = Scope.covering(scope(run_id: nil))

      assert %ScopeQuery{app_id: "mem0", run_id: nil} = app_rung
      assert %ScopeQuery{app_id: nil, run_id: nil} = user_rung
    end

    test "collapses to a single rung for a user-level address" do
      assert [%ScopeQuery{user_id: "christophe", app_id: nil, run_id: nil}] =
               Scope.covering(scope(app_id: nil, run_id: nil))
    end

    test "keeps a run rung that has no app above it" do
      assert [run_rung, user_rung] = Scope.covering(scope(app_id: nil))

      assert %ScopeQuery{app_id: nil, run_id: "session-1"} = run_rung
      assert %ScopeQuery{app_id: nil, run_id: nil} = user_rung
    end
  end

  describe "ScopeQuery.new/1" do
    test "leaves app_id and run_id nil, meaning any" do
      assert %ScopeQuery{app_id: nil, run_id: nil} = ScopeQuery.new(user_id: "christophe")
    end

    test "will not read across every user" do
      assert_raise ArgumentError, fn -> ScopeQuery.new(user_id: nil) end
    end
  end
end
