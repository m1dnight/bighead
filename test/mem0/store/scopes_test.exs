defmodule Mem0.Store.ScopesTest do
  @moduledoc """
  The scopes context: upsert on the `(user, project, session)` triple, lookup
  by id and by session, and the extraction watermark.
  """
  use Mem0.DataCase, async: true

  alias Mem0.Store.Scopes

  @attrs %{user: "christophe", project: "/code/widget", session: "session-1"}

  describe "create/1" do
    test "inserts a scope" do
      assert {:ok, scope} = Scopes.create(@attrs)
      assert scope.user == "christophe"
      assert scope.project == "/code/widget"
      assert scope.session == "session-1"
      assert scope.last_extracted_message_id == nil
    end

    test "the same triple upserts onto the same row" do
      assert {:ok, first} = Scopes.create(@attrs)
      assert {:ok, second} = Scopes.create(@attrs)

      assert second.id == first.id
      assert [_only_one] = Scopes.list()
    end

    test "a missing user fails validation" do
      assert {:error, changeset} = Scopes.create(%{project: "/code/widget"})
      assert %{user: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "lookup" do
    setup do
      {:ok, scope} = Scopes.create(@attrs)
      %{scope: scope}
    end

    test "get/1 returns the scope, or nil", %{scope: scope} do
      assert Scopes.get(scope.id).id == scope.id
      assert Scopes.get(scope.id + 1) == nil
    end

    test "get!/1 raises when the scope does not exist", %{scope: scope} do
      assert Scopes.get!(scope.id).id == scope.id
      assert_raise Ecto.NoResultsError, fn -> Scopes.get!(scope.id + 1) end
    end

    test "get_by_session/1 finds the one scope for a session", %{scope: scope} do
      assert {:ok, found} = Scopes.get_by_session("session-1")
      assert found.id == scope.id

      assert {:error, :session_does_not_exist} = Scopes.get_by_session("session-9")
    end
  end

  describe "set_last_extracted/2" do
    test "moves the watermark" do
      {:ok, scope} = Scopes.create(@attrs)

      assert {:ok, updated} = Scopes.set_last_extracted(scope, 42)
      assert updated.last_extracted_message_id == 42
      assert Scopes.get(scope.id).last_extracted_message_id == 42
    end
  end
end
