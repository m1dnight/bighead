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
    test "prefixes each message with its role, blank line between" do
      messages = [
        message(id: "m-1", role: :user, content: "I use Elixir.", seq: 1),
        message(id: "m-2", role: :assistant, content: "Noted.", seq: 2)
      ]

      assert Extraction.render(messages) == "user: I use Elixir.\n\nassistant: Noted."
    end

    test "orders by seq, not by the order it was handed" do
      messages = [
        message(id: "m-2", content: "second", seq: 2),
        message(id: "m-1", content: "first", seq: 1)
      ]

      assert Extraction.render(messages) == "user: first\n\nuser: second"
    end

    test "keeps the last 20 messages and drops the older ones" do
      messages = for seq <- 1..25, do: message(id: "m-#{seq}", content: "line #{seq}", seq: seq)

      rendered = Extraction.render(messages)

      refute rendered =~ "line 5\n"
      assert rendered =~ "line 6"
      assert rendered =~ "line 25"
      assert length(String.split(rendered, "\n\n")) == 20
    end

    test "truncates a long message and says so" do
      long = String.duplicate("a", 2_500)

      rendered = Extraction.render([message(content: long)])

      assert String.ends_with?(rendered, "…")
      assert String.length(rendered) == String.length("user: ") + 2_000 + 1
    end

    test "leaves a message at the cap alone" do
      exact = String.duplicate("a", 2_000)

      refute Extraction.render([message(content: exact)]) =~ "…"
    end

    test "is empty for no messages" do
      assert Extraction.render([]) == ""
    end
  end

  describe "request/1" do
    test "carries the system prompt, the transcript and the reply schema" do
      request = Extraction.request([message(content: "I use Elixir.")])

      assert request.system == Extraction.system_prompt()
      assert request.messages == [%{role: :user, content: "user: I use Elixir."}]
      assert request.schema["required"] == ["facts"]
      assert request.schema["properties"]["facts"]["items"]["type"] == "string"
      assert request.schema["additionalProperties"] == false
    end
  end

  describe "decode/4" do
    test "builds a fact per string, in the scope and at the instant given" do
      scope = scope(app_id: "widget")

      assert {:ok, extraction} =
               Extraction.decode(
                 ~s({"facts": ["Uses Elixir", "Runs tests before pushing"]}),
                 scope,
                 at(10),
                 ["m-1", "m-2"]
               )

      assert extraction.scope == scope
      assert extraction.prompt_at == at(10)
      assert extraction.source_message_ids == ["m-1", "m-2"]

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
      assert {:ok, extraction} = Extraction.decode(~s({"facts": []}), scope(), at(0), ["m-1"])
      assert extraction.facts == []
      assert extraction.source_message_ids == ["m-1"]
    end

    test "trims, and drops what is blank once trimmed" do
      reply = ~s({"facts": ["  Uses Elixir  ", "", "   "]})

      assert {:ok, extraction} = Extraction.decode(reply, scope(), at(0), [])
      assert Enum.map(extraction.facts, & &1.content) == ["Uses Elixir"]
    end

    test "collapses a fact the model said twice" do
      reply = ~s({"facts": ["Uses Elixir", "Uses Elixir", " Uses Elixir "]})

      assert {:ok, extraction} = Extraction.decode(reply, scope(), at(0), [])
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
        assert Extraction.decode(unquote(reply), scope(), at(0), ["m-1"]) ==
                 {:error, :malformed_facts}
      end
    end
  end
end
