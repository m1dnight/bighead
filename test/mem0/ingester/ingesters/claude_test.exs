defmodule Mem0.Ingester.ClaudeTest do
  @moduledoc """
  The string-level contract of the new ingester, plus one equivalence test
  that pins the port: on every captured fixture it must agree with the
  normaliser it supersedes. The rule-by-rule coverage lives with that old
  module (`Mem0.Core.Transcript.ClaudeCodeTest`) and migrates here when the
  old pipeline is rewired onto this one.
  """
  use ExUnit.Case, async: true
  use Mem0.CoreFixtures

  alias Mem0.Core.Transcript.ClaudeCode
  alias Mem0.Ingester.Claude
  alias Mem0.Ingester.Message
  alias Mem0.TranscriptFixtures

  doctest Claude

  @timestamp "2026-08-24T09:00:00.000Z"

  describe "ingest/1" do
    test "keeps user and assistant, in file order, with identity and time" do
      transcript = transcript([entry("user", "hello"), entry("assistant", "hi")])

      assert {:ok, [user, assistant]} = Claude.ingest(transcript)
      assert %Message{role: :user, content: "hello", id: "uuid-user-1"} = user
      assert %Message{role: :assistant, content: "hi"} = assistant
      assert user.said_at == ~U[2026-08-24 09:00:00.000000Z]
    end

    test "machinery produces no message and no error" do
      entries = [
        entry("system", "x"),
        entry("user", "hello", %{"isMeta" => true}),
        entry("user", "Search the repo.", %{"isSidechain" => true}),
        entry("user", [%{"type" => "tool_result", "content" => "ok"}]),
        entry("user", "<system-reminder>machine text</system-reminder>"),
        entry("user", "/compact")
      ]

      assert {:ok, []} = Claude.ingest(transcript(entries))
    end

    test "a wrapper strips and the person's own words survive" do
      entry = entry("user", "<ide_opened_file>foo.ex</ide_opened_file>fix the bug")

      assert {:ok, [message]} = Claude.ingest(transcript([entry]))
      assert message.content == "fix the bug"
    end

    test "an entry without a readable timestamp or uuid is dropped, not invented" do
      entries = [
        entry("user", "hello", %{"timestamp" => "not a time"}),
        entry("user", "hello", %{"uuid" => ""})
      ]

      assert {:ok, []} = Claude.ingest(transcript(entries))
    end

    test "a decodable non-entry line is dropped as malformed, not fatal" do
      transcript = Enum.join([Jason.encode!(entry("user", "hello")), "5", ~s("text")], "\n")

      assert {:ok, [%{content: "hello"}]} = Claude.ingest(transcript)
    end

    test "a line that does not decode fails the transcript, first failure wins" do
      transcript = Enum.join([Jason.encode!(entry("user", "hello")), "{not json", "{"], "\n")

      assert {:error, {:invalid_line, 2}} = Claude.ingest(transcript)
    end
  end

  describe "equivalence with the normaliser it supersedes" do
    test "agrees on every captured fixture" do
      for name <- TranscriptFixtures.names() do
        assert {:ok, messages} = Claude.ingest(TranscriptFixtures.raw(name))

        {old, _drops} = ClaudeCode.messages(TranscriptFixtures.entries(name), scope())

        assert Enum.map(messages, &{&1.id, &1.role, &1.content, &1.said_at}) ==
                 Enum.map(old, &{&1.id, &1.role, &1.content, &1.said_at}),
               "fixture #{name} diverged"
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
