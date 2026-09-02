defmodule Mem0.Ingester.ClaudeTest do
  @moduledoc """
  The contract of the Claude ingester, exercised through
  `Mem0.Ingester.decode_transcript/2` and the behaviour callbacks it is built
  from, plus a corpus check over every captured fixture.
  """
  use ExUnit.Case, async: true

  # Tolerated parse failures log a warning; captured so passing runs stay
  # quiet (the corpus fixtures contain such entries).
  import ExUnit.CaptureLog

  alias Mem0.Ingester
  alias Mem0.Ingester.Claude
  alias Mem0.TranscriptFixtures

  @moduletag :capture_log

  @timestamp "2026-08-24T09:00:00.000Z"

  describe "decode_transcript/2 with Claude" do
    test "keeps user and assistant, in file order, with identity, time and scope" do
      transcript = transcript([entry("user", "hello"), entry("assistant", "hi")])

      assert {:ok, scope, [user, assistant]} = Ingester.decode_transcript(transcript, Claude)
      assert scope == %{project: "/Users/example/Code/widget", session: "session-1"}
      assert %{role: "user", content: "hello", id: "uuid-user-1"} = user
      assert %{role: "assistant", content: "hi"} = assistant
      assert user.timestamp == ~U[2026-08-24 09:00:00.000Z]
    end

    test "machinery entries produce no message and no error" do
      entries = [
        entry("user", "hello"),
        entry("system", "x"),
        entry("file-history-snapshot", "x"),
        entry("user", "meta note", %{"isMeta" => true})
      ]

      assert {:ok, _scope, [%{content: "hello"}]} =
               Ingester.decode_transcript(transcript(entries), Claude)
    end

    test "an entry whose content decodes to nothing is dropped" do
      entries = [
        entry("user", "hello"),
        entry("user", [%{"type" => "tool_result", "content" => "ok"}])
      ]

      assert {:ok, _scope, [%{content: "hello"}]} =
               Ingester.decode_transcript(transcript(entries), Claude)
    end

    test "text blocks join and non-text blocks contribute nothing" do
      blocks = [%{"type" => "text", "text" => "part one"}, %{"type" => "tool_use"}]
      entries = [entry("user", "hi"), entry("assistant", blocks)]

      assert {:ok, _scope, [_user, %{content: "part one"}]} =
               Ingester.decode_transcript(transcript(entries), Claude)
    end

    test "an entry with an unreadable timestamp is dropped, the rest imports" do
      entries = [
        entry("user", "hello", %{"timestamp" => "not a time"}),
        entry("assistant", "hi")
      ]

      log =
        capture_log(fn ->
          assert {:ok, _scope, [%{content: "hi"}]} =
                   Ingester.decode_transcript(transcript(entries), Claude)
        end)

      assert log =~ "Failed to import some messages"
    end

    test "a line that does not decode fails the transcript" do
      transcript = Enum.join([Jason.encode!(entry("user", "hello")), "{not json", "{"], "\n")

      assert {:error, :decode_failed} = Ingester.decode_transcript(transcript, Claude)
    end
  end

  describe "skip_entry?/1" do
    test "an entry without a uuid is machinery" do
      assert Claude.skip_entry?(%{"type" => "user"})
    end

    test "a conversational entry with a uuid is kept" do
      refute Claude.skip_entry?(%{"type" => "user", "uuid" => "u-1"})
    end
  end

  describe "scope/1" do
    test "comes from the first user entry carrying cwd and sessionId" do
      entries = [
        entry("assistant", "hi"),
        entry("user", "a", %{"cwd" => "/first", "sessionId" => "s-1"}),
        entry("user", "b", %{"cwd" => "/second", "sessionId" => "s-2"})
      ]

      assert {:ok, %{project: "/first", session: "s-1"}} = Claude.scope(entries)
    end

    test "a transcript with no user entry has no session" do
      assert {:error, :no_session} = Claude.scope([entry("assistant", "hi")])
    end
  end

  describe "the captured corpus" do
    test "every fixture decodes into conversational messages" do
      for name <- TranscriptFixtures.names() do
        assert {:ok, scope, messages} =
                 Ingester.decode_transcript(TranscriptFixtures.raw(name), Claude),
               "fixture #{name} did not decode"

        assert is_binary(scope.project) and is_binary(scope.session)

        for message <- messages do
          assert message.role in ["user", "assistant"], "fixture #{name} leaked a role"
          assert is_binary(message.content) and message.content != ""
          assert %DateTime{} = message.timestamp
          assert is_binary(message.id)
        end
      end
    end
  end

  defp transcript(entries), do: Enum.map_join(entries, "\n", &Jason.encode!/1)

  # Shaped the way a real entry is shaped, with the fields the rules read. The
  # `overrides` map is merged last so a test can delete or corrupt any of them.
  defp entry(type, content, overrides \\ %{}) do
    Map.merge(
      %{
        "type" => type,
        "uuid" => "uuid-" <> type <> "-1",
        "timestamp" => @timestamp,
        "parentUuid" => nil,
        "isSidechain" => false,
        "cwd" => "/Users/example/Code/widget",
        "sessionId" => "session-1",
        "version" => "2.1.241",
        "message" => %{"role" => type, "content" => content}
      },
      overrides
    )
  end
end
