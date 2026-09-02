defmodule Mem0.ImporterTest do
  @moduledoc """
  Whole-file import through the Claude ingester: one scope, its messages,
  and the idempotence that makes re-posting the same file safe.
  """
  use Mem0.DataCase, async: true

  alias Mem0.Importer
  alias Mem0.Ingester.Claude
  alias Mem0.Store.Messages
  alias Mem0.Store.Scopes

  @timestamp "2026-08-24T09:00:00.000Z"

  describe "import_transcript/2" do
    test "stores the scope and every conversational message" do
      transcript = transcript([entry("user", "hello"), entry("assistant", "hi")])

      assert {:ok, returned_scope, messages} = Importer.import_transcript(transcript, Claude)
      assert length(messages) == 2

      assert [scope] = Scopes.list()
      assert returned_scope.id == scope.id
      assert scope.user == "default"
      assert scope.project == "/Users/example/Code/widget"
      assert scope.session == "session-1"

      contents = Messages.list() |> Enum.map(& &1.content) |> Enum.sort()
      assert contents == ["hello", "hi"]
      assert Enum.all?(Messages.list(), &(&1.scope_id == scope.id))
    end

    test "importing the same transcript twice stores nothing new" do
      transcript = transcript([entry("user", "hello"), entry("assistant", "hi")])

      assert {:ok, _scope, _first} = Importer.import_transcript(transcript, Claude)
      assert {:ok, _scope, _second} = Importer.import_transcript(transcript, Claude)

      assert [_scope] = Scopes.list()
      assert length(Messages.list()) == 2
    end

    test "a transcript that does not decode stores nothing" do
      transcript = Enum.join([Jason.encode!(entry("user", "hello")), "{not json"], "\n")

      assert {:error, :decode_failed} = Importer.import_transcript(transcript, Claude)
      assert Scopes.list() == []
      assert Messages.list() == []
    end

    test "a transcript without a scope stores nothing" do
      transcript = transcript([entry("assistant", "hi")])

      assert {:error, :no_session} = Importer.import_transcript(transcript, Claude)
      assert Scopes.list() == []
    end
  end

  defp transcript(entries), do: Enum.map_join(entries, "\n", &Jason.encode!/1)

  defp entry(type, content) do
    %{
      "type" => type,
      "uuid" => "uuid-" <> type <> "-1",
      "timestamp" => @timestamp,
      "cwd" => "/Users/example/Code/widget",
      "sessionId" => "session-1",
      "message" => %{"role" => type, "content" => content}
    }
  end
end
