defmodule Bighead.Store.ScopesTest do
  @moduledoc """
  The scopes context: upsert on the `(user, project, session)` triple, lookup
  by id and by session, and the extraction watermark.
  """
  use Bighead.DataCase, async: true

  alias Bighead.Store.Diffs
  alias Bighead.Store.Messages
  alias Bighead.Store.Scopes

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

  describe "stale/0" do
    test "a scope with no messages is not stale" do
      {:ok, _scope} = Scopes.create(@attrs)

      assert Scopes.stale() == []
    end

    test "a never-extracted scope with a message is stale" do
      {:ok, scope} = Scopes.create(@attrs)
      {:ok, _message} = Messages.create(message_attrs(scope, "hello"))

      assert [stale] = Scopes.stale()
      assert stale.id == scope.id
    end

    test "a scope extracted up to its last message is not stale, and appears once past it" do
      {:ok, scope} = Scopes.create(@attrs)
      {:ok, first} = Messages.create(message_attrs(scope, "hello"))
      {:ok, scope} = Scopes.set_last_extracted(scope, first.id)

      assert Scopes.stale() == []

      {:ok, _second} = Messages.create(message_attrs(scope, "again", 1))
      {:ok, _third} = Messages.create(message_attrs(scope, "more", 2))

      assert [_only_once] = Scopes.stale()
    end
  end

  describe "set_last_extracted_diff/2" do
    test "moves the diff watermark" do
      {:ok, scope} = Scopes.create(@attrs)

      assert {:ok, updated} = Scopes.set_last_extracted_diff(scope, 42)
      assert updated.last_extracted_diff_id == 42
      assert Scopes.get(scope.id).last_extracted_diff_id == 42
    end
  end

  describe "stale_diffs/0" do
    test "a scope with no diffs is not stale" do
      {:ok, _scope} = Scopes.create(@attrs)

      assert Scopes.stale_diffs() == []
    end

    test "a never-extracted scope with a diff is stale" do
      {:ok, scope} = Scopes.create(@attrs)
      {:ok, _diff} = Diffs.create(diff_attrs(scope, "one"))

      assert [stale] = Scopes.stale_diffs()
      assert stale.id == scope.id
    end

    test "a scope extracted up to its last diff is not stale, and appears once past it" do
      {:ok, scope} = Scopes.create(@attrs)
      {:ok, first} = Diffs.create(diff_attrs(scope, "one"))
      {:ok, scope} = Scopes.set_last_extracted_diff(scope, first.id)

      assert Scopes.stale_diffs() == []

      {:ok, _second} = Diffs.create(diff_attrs(scope, "two"))
      {:ok, _third} = Diffs.create(diff_attrs(scope, "three"))

      assert [_only_once] = Scopes.stale_diffs()
    end
  end

  defp diff_attrs(scope, diff) do
    %{scope_id: scope.id, file: "lib/foo.ex", diff: diff}
  end

  defp message_attrs(scope, content, seconds \\ 0) do
    %{
      scope_id: scope.id,
      role: "user",
      content: content,
      timestamp: DateTime.add(~U[2026-08-24 09:00:00.000000Z], seconds, :second)
    }
  end
end
