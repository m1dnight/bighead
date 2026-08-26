defmodule Mem0.Core.ExtractionTest do
  @moduledoc """
  The two pure halves of an extraction: what the model is asked, and what is
  made of what it answers.

  `decode/4`'s tests are mostly malformed input, on purpose. It reads output
  from a model, and the interesting question about it is never the happy path.
  """
  use ExUnit.Case, async: true
  use Mem0.CoreFixtures

  doctest Extraction

  describe "render/1" do
    test "sections the prompt: summary, then context, then the new exchange" do
      prompt =
        prompt(
          summary: summary(text: "The user uses Elixir."),
          recent: [message(id: "m-1", content: "Earlier remark.", seq: 1)],
          new: [
            message(id: "m-2", content: "I use tabs.", seq: 2),
            message(id: "m-3", role: :assistant, content: "Noted.", seq: 3)
          ]
        )

      assert Extraction.render(prompt) == """
             # Conversation summary
             The user uses Elixir.

             # Earlier messages (context)
             user: Earlier remark.

             # New messages (extract from these only)
             user: I use tabs.

             assistant: Noted.\
             """
    end

    test "no summary means no summary section, not an empty ceremony one" do
      rendered = Extraction.render(prompt(summary: nil))

      refute rendered =~ "# Conversation summary"
      assert rendered =~ "# Earlier messages (context)"
    end

    test "no recent context drops its section the same way" do
      rendered = Extraction.render(prompt(summary: nil, recent: []))

      refute rendered =~ "# Earlier"

      assert rendered ==
               "# New messages (extract from these only)\n" <>
                 "user: I live in San Francisco.\n\nassistant: I live in San Francisco."
    end

    test "orders each section by seq, not by the order it was handed" do
      prompt =
        prompt(
          summary: nil,
          recent: [
            message(id: "m-2", content: "second", seq: 2),
            message(id: "m-1", content: "first", seq: 1)
          ],
          new: [
            message(id: "m-4", content: "fourth", seq: 4),
            message(id: "m-3", content: "third", seq: 3)
          ]
        )

      assert Extraction.render(prompt) == """
             # Earlier messages (context)
             user: first

             user: second

             # New messages (extract from these only)
             user: third

             user: fourth\
             """
    end

    test "keeps the last 20 recent messages and drops the older ones" do
      recent = for seq <- 1..25, do: message(id: "m-#{seq}", content: "line #{seq}", seq: seq)
      new = [message(id: "m-26", content: "the exchange", seq: 26)]

      rendered = Extraction.render(prompt(summary: nil, recent: recent, new: new))

      refute rendered =~ "line 5\n"
      assert rendered =~ "line 6"
      assert rendered =~ "line 25"
    end

    test "a new exchange past 20 messages comes through whole" do
      new = for seq <- 1..25, do: message(id: "m-#{seq}", content: "line #{seq}", seq: seq)

      rendered = Extraction.render(prompt(summary: nil, recent: [], new: new))

      assert rendered =~ "line 1\n"
      assert rendered =~ "line 25"
    end

    test "truncates a long message in either section and says so" do
      long = String.duplicate("a", 2_500)

      rendered =
        Extraction.render(
          prompt(
            summary: nil,
            recent: [message(id: "m-1", content: long, seq: 1)],
            new: [message(id: "m-2", content: long, seq: 2)]
          )
        )

      assert length(String.split(rendered, "…")) == 3
      refute rendered =~ String.duplicate("a", 2_001)
    end

    test "leaves a message at the cap alone" do
      exact = String.duplicate("a", 2_000)

      refute Extraction.render(prompt(new: [message(content: exact)])) =~ "…"
    end
  end

  describe "request/1" do
    test "carries the system prompt, the rendered prompt and the reply schema" do
      prompt = prompt(summary: nil, recent: [], new: [message(content: "I use Elixir.")])

      request = Extraction.request(prompt)

      assert request.system == Extraction.system_prompt()

      assert request.messages == [
               %{
                 role: :user,
                 content: "# New messages (extract from these only)\nuser: I use Elixir."
               }
             ]

      assert request.schema["required"] == ["facts"]
      assert request.schema["properties"]["facts"]["items"]["type"] == "string"
      assert request.schema["additionalProperties"] == false
    end
  end

  describe "decode/5" do
    test "builds a fact per string, in the scope and at the instant given" do
      scope = scope(app_id: "widget")

      assert {:ok, extraction} =
               Extraction.decode(
                 ~s({"facts": ["Uses Elixir", "Runs tests before pushing"]}),
                 scope,
                 at(10),
                 ["m-1", "m-2"],
                 7
               )

      assert extraction.scope == scope
      assert extraction.prompt_at == at(10)
      assert extraction.source_message_ids == ["m-1", "m-2"]
      assert extraction.through_seq == 7

      assert Enum.map(extraction.facts, & &1.content) == [
               "Uses Elixir",
               "Runs tests before pushing"
             ]

      assert Enum.all?(extraction.facts, &(&1.scope == scope))
      assert Enum.all?(extraction.facts, &(&1.extracted_at == at(10)))
      assert Enum.all?(extraction.facts, &(&1.source_message_ids == ["m-1", "m-2"]))
      assert Enum.all?(extraction.facts, &is_nil(&1.event_time))
    end

    test "no facts is a valid extraction, not a failure" do
      assert {:ok, extraction} = Extraction.decode(~s({"facts": []}), scope(), at(0), ["m-1"], 1)
      assert extraction.facts == []
      assert extraction.source_message_ids == ["m-1"]
      # The extraction still names its extent: the messages were considered,
      # even though nothing came out.
      assert extraction.through_seq == 1
    end

    test "trims, and drops what is blank once trimmed" do
      reply = ~s({"facts": ["  Uses Elixir  ", "", "   "]})

      assert {:ok, extraction} = Extraction.decode(reply, scope(), at(0), [], 1)
      assert Enum.map(extraction.facts, & &1.content) == ["Uses Elixir"]
    end

    test "collapses a fact the model said twice" do
      reply = ~s({"facts": ["Uses Elixir", "Uses Elixir", " Uses Elixir "]})

      assert {:ok, extraction} = Extraction.decode(reply, scope(), at(0), [], 1)
      assert Enum.map(extraction.facts, & &1.content) == ["Uses Elixir"]
    end

    for {name, reply} <- [
          {"a reply that is not JSON at all", "I could not find any facts, sorry!"},
          {"a reply that is truncated JSON", ~s({"facts": ["Uses Eli)},
          {"JSON with no facts key", ~s({"memories": ["Uses Elixir"]})},
          {"facts that is not a list", ~s({"facts": "Uses Elixir"})},
          {"facts holding something that is not a string",
           ~s({"facts": [{"text": "Uses Elixir"}]})},
          {"facts holding a null", ~s({"facts": ["Uses Elixir", null]})},
          {"a bare JSON array", ~s(["Uses Elixir"])},
          {"an empty reply", ""}
        ] do
      test "#{name} is malformed rather than a raise" do
        assert Extraction.decode(unquote(reply), scope(), at(0), ["m-1"], 1) ==
                 {:error, :malformed_facts}
      end
    end
  end
end
