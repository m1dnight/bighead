defmodule Bighead.Store.MessagesTest do
  @moduledoc """
  The messages context: dedup on `(scope, timestamp, role, content)`, the
  session and project reads with their ordering, and validation at the edge.
  """
  use Bighead.DataCase, async: true

  alias Bighead.Store.Messages
  alias Bighead.Store.Scopes

  @epoch ~U[2026-08-24 09:00:00.000000Z]

  setup do
    {:ok, scope} = Scopes.create(%{user: "u", project: "/code/widget", session: "session-1"})
    %{scope: scope}
  end

  describe "create/1" do
    test "inserts a message", %{scope: scope} do
      assert {:ok, message} = Messages.create(attrs(scope, "hello", 0))
      assert message.role == "user"
      assert message.content == "hello"
      assert message.embedding_768 == nil
    end

    test "re-ingesting the same message lands on the same row", %{scope: scope} do
      assert {:ok, first} = Messages.create(attrs(scope, "hello", 0))
      assert {:ok, second} = Messages.create(attrs(scope, "hello", 0))

      assert second.id == first.id
      assert [_only_one] = Messages.list()
    end

    test "a role outside the conversation is rejected", %{scope: scope} do
      attrs = %{attrs(scope, "x", 0) | role: "robot"}

      assert {:error, changeset} = Messages.create(attrs)
      assert %{role: ["is invalid"]} = errors_on(changeset)
    end

    test "a message cannot point at a scope that does not exist", %{scope: scope} do
      attrs = %{attrs(scope, "x", 0) | scope_id: scope.id + 1}

      assert {:error, changeset} = Messages.create(attrs)
      assert %{scope_id: ["does not exist"]} = errors_on(changeset)
    end
  end

  describe "get_session/2" do
    test "returns the session's conversation sorted by id", %{scope: scope} do
      {:ok, first} = Messages.create(attrs(scope, "one", 0))
      {:ok, second} = Messages.create(attrs(scope, "two", 1))

      {:ok, other} = Scopes.create(%{user: "u", project: "/code/other", session: "session-2"})
      {:ok, _elsewhere} = Messages.create(attrs(other, "elsewhere", 2))

      assert [%{id: a}, %{id: b}] = Messages.get_session("session-1")
      assert {a, b} == {first.id, second.id}
    end

    test ":from returns only messages past the watermark", %{scope: scope} do
      {:ok, first} = Messages.create(attrs(scope, "one", 0))
      {:ok, second} = Messages.create(attrs(scope, "two", 1))

      assert [%{id: id}] = Messages.get_session("session-1", from: first.id)
      assert id == second.id

      assert [] == Messages.get_session("session-1", from: second.id)
    end
  end

  describe "get_project/1" do
    test "spans sessions and sorts by timestamp", %{scope: scope} do
      {:ok, other} = Scopes.create(%{user: "u", project: "/code/widget", session: "session-2"})

      {:ok, _late} = Messages.create(attrs(scope, "late", 10))
      {:ok, _early} = Messages.create(attrs(other, "early", 1))

      assert ["early", "late"] = Enum.map(Messages.get_project("/code/widget"), & &1.content)
      assert [] == Messages.get_project("/code/nowhere")
    end
  end

  describe "update/2" do
    test "changes the stored message", %{scope: scope} do
      {:ok, message} = Messages.create(attrs(scope, "hello", 0))

      assert {:ok, updated} = Messages.update(message, %{content: "goodbye"})
      assert updated.content == "goodbye"
      assert Messages.get!(message.id).content == "goodbye"
    end
  end

  defp attrs(scope, content, seconds) do
    %{
      scope_id: scope.id,
      role: "user",
      content: content,
      timestamp: DateTime.add(@epoch, seconds, :second)
    }
  end
end
