defmodule Mem0.Core.Transcript.ClaudeCodeTest do
  @moduledoc """
  The normaliser's whole job is to be *total* over a format nobody controls, so
  these tests are as much about what it refuses to raise on as about what it
  reads.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties
  use Mem0.CoreFixtures

  import Mem0.TranscriptFixtures

  alias Mem0.Core.Transcript.ClaudeCode

  doctest ClaudeCode, import: true

  @timestamp "2026-08-24T09:00:00.000Z"

  describe "rule 1: type" do
    test "keeps user and assistant" do
      assert {[user, assistant], []} =
               ClaudeCode.messages(
                 [entry("user", "hello"), entry("assistant", "hi")],
                 scope()
               )

      assert user.role == :user
      assert assistant.role == :assistant
    end

    test "reports every other type by name, never as an aggregate" do
      entries = Enum.map(~w(attachment system summary queue-operation), &entry(&1, "x"))

      assert {[], drops} = ClaudeCode.messages(entries, scope())

      assert drops == [
               {:unsupported_type, "attachment"},
               {:unsupported_type, "system"},
               {:unsupported_type, "summary"},
               {:unsupported_type, "queue-operation"}
             ]
    end

    test "a missing or non-string type is malformed, not an unsupported type" do
      assert {[], [:malformed, :malformed]} =
               ClaudeCode.messages([%{"uuid" => "u"}, %{"type" => 7}], scope())
    end
  end

  describe "rules 2 and 3: meta and sidechain" do
    test "isMeta drops before anything reads the content" do
      assert {[], [:meta]} =
               ClaudeCode.messages([entry("user", "hello", %{"isMeta" => true})], scope())
    end

    test "isCompactSummary drops as meta" do
      entry = entry("assistant", "Here is what happened.", %{"isCompactSummary" => true})

      assert {[], [:meta]} = ClaudeCode.messages([entry], scope())
    end

    # A `/compact` produces two entries with the same text: one wrapped in
    # `<command-name>`, and one recording exactly what the user typed. The
    # second carries no wrapper and — measured on v2.1.241 — no `origin` key
    # either, so it is the one rule that catches it.
    test "a bare slash command is not something anyone said" do
      for command <- ["/compact", "/effort", "/model:opus", "/my-command"] do
        assert {[], [:synthetic]} = ClaudeCode.messages([entry("user", command)], scope())
      end
    end

    test "a path or a sentence that opens with a slash is kept" do
      for text <- ["/dev/ingest", "/usr/local/bin is on my PATH", "/tmp holds the scratch files"] do
        assert {[message], []} = ClaudeCode.messages([entry("user", text)], scope())
        assert message.content == text
      end
    end

    test "a subagent's turns are not the user's conversation" do
      entry = entry("user", "Search the repo.", %{"isSidechain" => true})

      assert {[], [:sidechain]} = ClaudeCode.messages([entry], scope())
    end

    test "isSidechain: false is not a drop" do
      entry = entry("user", "hello", %{"isSidechain" => false})

      assert {[_message], []} = ClaudeCode.messages([entry], scope())
    end
  end

  describe "rule 4: role \"user\" does not mean a person typed it" do
    test "a slash command invocation strips to empty" do
      content =
        "<command-name>/effort</command-name><command-message>effort</command-message>" <>
          "<command-args></command-args>"

      assert {[], [:synthetic]} = ClaudeCode.messages([entry("user", content)], scope())
    end

    test "its stdout and caveat strip to empty too" do
      for content <- [
            "<local-command-stdout>Set effort level to low</local-command-stdout>",
            "<local-command-caveat>Caveat: the messages below…</local-command-caveat>",
            "<system-reminder>Remember to use the tool.</system-reminder>"
          ] do
        assert {[], [:synthetic]} = ClaudeCode.messages([entry("user", content)], scope())
      end
    end

    test "a real message keeps its human half when a wrapper is appended" do
      content = [
        %{
          "type" => "text",
          "text" => "<ide_opened_file>The user opened mix.exs</ide_opened_file>"
        },
        %{"type" => "text", "text" => "and i work on this from a mac"}
      ]

      assert {[message], []} = ClaudeCode.messages([entry("user", content)], scope())
      assert message.content == "and i work on this from a mac"
    end

    test "an unbalanced wrapper strips to end of input rather than being kept" do
      content = "<ide_selection>lines 4-9 of mix.exs, no closing tag ever arrives"

      assert {[], [:synthetic]} = ClaudeCode.messages([entry("user", content)], scope())
    end

    test "a leading orphan closing tag is stripped and the rest survives" do
      content = "</task-notification>\n\ndid that agent finish?"

      assert {[message], []} = ClaudeCode.messages([entry("user", content)], scope())
      assert message.content == "did that agent finish?"
    end

    test "a non-human origin drops even with no recognisable wrapper" do
      entry = entry("user", "Agent finished: 3 files changed", %{"origin" => %{"kind" => "task"}})

      assert {[], [:synthetic]} = ClaudeCode.messages([entry], scope())
    end

    test "an absent origin does not fire the origin test, so old versions still ingest" do
      assert {[message], []} =
               ClaudeCode.messages([entry("user", "i prefer tabs")], scope())

      assert message.content == "i prefer tabs"
    end

    test "an unrecognised wrapper is kept: only a closed list is safe" do
      content = "<query>select 1</query> is what i ran"

      assert {[message], []} = ClaudeCode.messages([entry("user", content)], scope())
      assert message.content == "<query>select 1</query> is what i ran"
    end

    test "assistant text is never treated as synthetic" do
      entry = entry("assistant", "<command-name>/effort</command-name>")

      assert {[message], []} = ClaudeCode.messages([entry], scope())
      assert message.content == "<command-name>/effort</command-name>"
    end
  end

  describe "rule 5: tool results are not utterances" do
    test "a user entry carrying a tool_result drops whole" do
      content = [
        %{"type" => "tool_result", "tool_use_id" => "toolu_01", "content" => "lib/widget.ex"}
      ]

      assert {[], [:tool_result]} = ClaudeCode.messages([entry("user", content)], scope())
    end

    test "the drop is reported as a tool result, not as synthetic or missing text" do
      entries = entries("tool_heavy")

      assert {_messages, drops} = ClaudeCode.messages(entries, scope())
      assert :tool_result in drops
      refute :synthetic in drops
    end
  end

  describe "rule 6: what is left of a turn" do
    test "thinking and tool_use blocks are dropped, text is kept" do
      content = [
        %{"type" => "thinking", "thinking" => "they said tabs", "signature" => "sig"},
        %{"type" => "text", "text" => "Noted — tabs it is."},
        %{"type" => "tool_use", "id" => "toolu_01", "name" => "Bash", "input" => %{}}
      ]

      assert {[message], []} = ClaudeCode.messages([entry("assistant", content)], scope())
      assert message.content == "Noted — tabs it is."
    end

    test "an assistant turn that is all thinking has nothing left" do
      content = [%{"type" => "thinking", "thinking" => "hmm", "signature" => "sig"}]

      assert {[], [:no_text]} = ClaudeCode.messages([entry("assistant", content)], scope())
    end

    test "an entry that never had text is :no_text, not :synthetic" do
      assert {[], [:no_text]} = ClaudeCode.messages([entry("user", [])], scope())
      assert {[], [:no_text]} = ClaudeCode.messages([entry("user", "   ")], scope())
    end

    test "several text blocks are joined" do
      content = [
        %{"type" => "text", "text" => "first"},
        %{"type" => "text", "text" => "second"}
      ]

      assert {[message], []} = ClaudeCode.messages([entry("assistant", content)], scope())
      assert message.content == "first\nsecond"
    end
  end

  describe "rule 7: timestamps are never invented" do
    test "an unparseable timestamp drops the entry" do
      entry = entry("user", "hello", %{"timestamp" => "yesterday"})

      assert {[], [:unparseable_timestamp]} = ClaudeCode.messages([entry], scope())
    end

    test "a missing timestamp drops it too" do
      entry = "user" |> entry("hello") |> Map.delete("timestamp")

      assert {[], [:unparseable_timestamp]} = ClaudeCode.messages([entry], scope())
    end

    test "said_at is the entry's own instant" do
      assert {[message], []} = ClaudeCode.messages([entry("user", "hello")], scope())
      assert message.said_at == ~U[2026-08-24 09:00:00.000Z]
    end
  end

  describe "rule 8: shapes that do not fit" do
    test "a missing or blank uuid is malformed" do
      no_uuid = "user" |> entry("hello") |> Map.delete("uuid")
      blank = entry("user", "hello", %{"uuid" => "  "})

      assert {[], [:malformed, :malformed]} = ClaudeCode.messages([no_uuid, blank], scope())
    end

    test "a message that is not a map, or content that is neither string nor list" do
      no_message = "user" |> entry("hello") |> Map.put("message", "oops")
      bad_content = entry("user", 7)

      assert {[], [:malformed, :malformed]} =
               ClaudeCode.messages([no_message, bad_content], scope())
    end

    test "a non-map entry does not raise" do
      assert {[], [:malformed, :malformed, :malformed]} =
               ClaudeCode.messages([nil, "line", 42], scope())
    end

    test "non-map blocks inside a block list are ignored rather than fatal" do
      content = ["junk", %{"type" => "text", "text" => "still here"}, 7]

      assert {[message], []} = ClaudeCode.messages([entry("user", content)], scope())
      assert message.content == "still here"
    end
  end

  describe "seq is absolute within the run" do
    test "it counts transcript lines from the offset, including dropped ones" do
      entries = [entry("attachment", "x"), entry("user", "hello"), entry("assistant", "hi")]

      assert {[user, assistant], [{:unsupported_type, "attachment"}]} =
               ClaudeCode.messages(entries, scope(), 100)

      assert user.seq == 101
      assert assistant.seq == 102
    end

    test "two overlapping batches agree on the seq of the messages they share" do
      run = Enum.map(0..9, &entry("user", "line #{&1}", %{"uuid" => "u#{&1}"}))

      # Two `Stop` batches taken as the run grew: the first eight lines, then
      # the last eight. The tail is re-sent every turn, so this is the normal
      # case rather than an edge one.
      {first, []} = ClaudeCode.messages(Enum.slice(run, 0, 8), scope(), 0)
      {second, []} = ClaudeCode.messages(Enum.slice(run, 2, 8), scope(), 2)

      shared = fn messages -> Map.new(messages, &{&1.id, &1.seq}) end

      overlap =
        first
        |> shared.()
        |> Map.keys()
        |> MapSet.new()
        |> MapSet.intersection(second |> shared.() |> Map.keys() |> MapSet.new())

      assert MapSet.size(overlap) == 6

      for id <- overlap do
        assert shared.(first)[id] == shared.(second)[id]
      end
    end

    test "the default offset is zero" do
      assert {[message], []} = ClaudeCode.messages([entry("user", "hello")], scope())
      assert message.seq == 0
    end
  end

  describe "the scope it is given" do
    test "every message carries it, unchanged" do
      scope = scope(app_id: "widget", run_id: "session-9")
      entries = [entry("user", "hello"), entry("assistant", "hi")]

      assert {messages, []} = ClaudeCode.messages(entries, scope)
      assert Enum.all?(messages, &(&1.scope == scope))
    end

    test "a blank optional id normalises before it ever reaches a message" do
      scope = Scope.new(user_id: "christophe", app_id: "  ", run_id: "session-1")

      assert {[message], []} = ClaudeCode.messages([entry("user", "hello")], scope)
      assert message.scope.app_id == nil
    end
  end

  describe "ordering" do
    test "messages come back oldest first, and drops in the order they occurred" do
      entries = [
        entry("user", "one", %{"uuid" => "u1"}),
        entry("attachment", "x"),
        entry("assistant", "two", %{"uuid" => "u2"}),
        entry("user", [%{"type" => "tool_result", "tool_use_id" => "t"}], %{"uuid" => "u3"}),
        entry("user", "three", %{"uuid" => "u4"})
      ]

      assert {messages, drops} = ClaudeCode.messages(entries, scope())
      assert Enum.map(messages, & &1.content) == ["one", "two", "three"]
      assert drops == [{:unsupported_type, "attachment"}, :tool_result]
    end
  end

  describe "the fixtures" do
    test "a plain exchange reads as four messages" do
      assert {messages, []} = ClaudeCode.messages(entries("plain_exchange"), scope())

      assert Enum.map(messages, & &1.role) == [:user, :assistant, :user, :assistant]
      assert Enum.at(messages, 2).content == "and i work on this repo from a mac, always"
    end

    test "a tool-heavy turn ingests the prompt and the answer and nothing between" do
      assert {messages, drops} = ClaudeCode.messages(entries("tool_heavy"), scope())

      assert Enum.map(messages, & &1.content) == [
               "list the files under lib and tell me which one is the entry point",
               "`lib/widget.ex` is the entry point."
             ]

      # The assistant turn that only calls a tool has nothing left to say.
      assert Enum.sort(drops) == [
               :no_text,
               :tool_result,
               {:unsupported_type, "attachment"},
               {:unsupported_type, "file-history-snapshot"}
             ]
    end

    test "a session of slash commands ingests only the sentence in the middle of them" do
      assert {messages, drops} = ClaudeCode.messages(entries("slash_commands"), scope())

      assert Enum.map(messages, & &1.content) == [
               "my postgres runs in docker, never locally",
               "Got it."
             ]

      assert Enum.sort(drops) == [:meta, :synthetic, :synthetic, :synthetic]
    end

    test "a version predating origin still ingests its real prompt" do
      entries = entries("pre_origin")

      refute Enum.any?(entries, &Map.has_key?(&1, "origin"))

      assert {messages, [:synthetic]} = ClaudeCode.messages(entries, scope())

      assert Enum.map(messages, & &1.content) == [
               "i live in belgium and only want remote roles in the EU",
               "Filtering to remote EU roles."
             ]
    end

    test "a subagent's turns are dropped and the main chain is not" do
      assert {messages, drops} = ClaudeCode.messages(entries("subagent"), scope())

      assert drops == [:sidechain, :sidechain]

      assert Enum.map(messages, & &1.content) == [
               "find every call site of Widget.new/1",
               "There are four call sites."
             ]
    end

    test "a compacted session ingests the conversation and none of the compaction" do
      entries = entries("compacted")

      assert {messages, drops} = ClaudeCode.messages(entries, scope())

      assert Enum.map(messages, & &1.content) == [
               "i keep my postgres in docker, never on the host",
               "Noted.",
               "right, where were we",
               "Your database setup — Postgres in Docker."
             ]

      # The summary is a message nobody said; the boundary and the recap are
      # their own entry types; the invocation leaves a caveat and two wrappers.
      assert Enum.sort(drops) == [
               :meta,
               :meta,
               :synthetic,
               :synthetic,
               :synthetic,
               {:unsupported_type, "system"},
               {:unsupported_type, "system"}
             ]
    end

    test "the compact summary is dropped for being a summary, not for its shape" do
      summary =
        "compacted" |> entries() |> Enum.find(&Map.get(&1, "isCompactSummary"))

      assert summary["type"] == "user"
      assert is_binary(summary["message"]["content"])
      assert {[], [:meta]} = ClaudeCode.messages([summary], scope())
    end

    test "every fixture returns a tuple and raises on nothing" do
      for name <- names() do
        assert {messages, drops} = ClaudeCode.messages(entries(name), scope(), 7)
        assert is_list(messages) and is_list(drops)
        assert length(messages) + length(drops) == length(entries(name))
      end
    end
  end

  describe "totality" do
    property "any JSON-shaped list of entries returns a tuple and never raises" do
      check all(
              entries <- list_of(json_term(), max_length: 12),
              offset <- integer(0..1000)
            ) do
        assert {messages, drops} = ClaudeCode.messages(entries, scope(), offset)
        assert length(messages) + length(drops) == length(entries)
      end
    end

    property "an entry with arbitrary values under the keys it reads still returns a tuple" do
      check all(
              type <- one_of([constant("user"), constant("assistant"), json_term()]),
              content <- json_term(),
              timestamp <- one_of([constant(@timestamp), json_term()]),
              extra <- map_of(string(:alphanumeric, max_length: 8), json_term(), max_length: 4)
            ) do
        entry =
          Map.merge(extra, %{
            "type" => type,
            "uuid" => "u1",
            "timestamp" => timestamp,
            "message" => %{"role" => "user", "content" => content}
          })

        assert {messages, drops} = ClaudeCode.messages([entry], scope())
        assert length(messages) + length(drops) == 1
      end
    end
  end

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

  # Anything `Jason.decode/1` can produce, one level of nesting deep. The point
  # is not to be exhaustive about JSON but to make sure no shape reaches a
  # `Map.fetch!/2` or an unguarded pattern match.
  defp json_scalar do
    one_of([
      constant(nil),
      boolean(),
      integer(),
      float(),
      string(:printable, max_length: 20)
    ])
  end

  defp json_term do
    one_of([
      json_scalar(),
      list_of(json_scalar(), max_length: 4),
      map_of(string(:alphanumeric, max_length: 8), json_scalar(), max_length: 4),
      map_of(
        string(:alphanumeric, max_length: 8),
        map_of(string(:alphanumeric, max_length: 8), json_scalar(), max_length: 2),
        max_length: 3
      )
    ])
  end
end
