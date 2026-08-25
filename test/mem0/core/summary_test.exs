defmodule Mem0.Core.SummaryTest do
  @moduledoc """
  The two pure halves of a regeneration — what the model is asked, and what is
  made of what it answers — plus the staleness comparison the `Stop` pulse
  drives.

  `decode/4`'s tests are mostly malformed input, on purpose. It reads output
  from a model, and the interesting question about it is never the happy path.
  """
  use ExUnit.Case, async: true
  use Mem0.CoreFixtures

  describe "stale?/2" do
    test "nothing pending is never stale" do
      refute Summary.stale?(0, 0)
    end

    test "is fresh at exactly max_lag pending" do
      refute Summary.stale?(2, 2)
    end

    test "goes stale one message past max_lag" do
      assert Summary.stale?(3, 2)
    end
  end

  describe "stale?/1" do
    test "falls back to the default lag" do
      refute Summary.stale?(10)
      assert Summary.stale?(11)
    end
  end

  describe "render/1" do
    test "prefixes each message with its role, blank line between" do
      messages = [
        message(id: "m-1", role: :user, content: "I use Elixir.", seq: 1),
        message(id: "m-2", role: :assistant, content: "Noted.", seq: 2)
      ]

      assert Summary.render(messages) == "user: I use Elixir.\n\nassistant: Noted."
    end

    test "orders by seq, not by the order it was handed" do
      messages = [
        message(id: "m-2", content: "second", seq: 2),
        message(id: "m-1", content: "first", seq: 1)
      ]

      assert Summary.render(messages) == "user: first\n\nuser: second"
    end

    test "renders every message it is given — no count cap" do
      # Comfortably past the cap extraction's render keeps (20), because the
      # difference is the point: a message dropped here is a fact `S` can
      # never state.
      messages = for seq <- 1..40, do: message(id: "m-#{seq}", content: "line #{seq}", seq: seq)

      rendered = Summary.render(messages)

      assert rendered =~ "line 1\n"
      assert rendered =~ "line 40"
      assert length(String.split(rendered, "\n\n")) == 40
    end

    test "truncates a long message and says so" do
      long = String.duplicate("a", 2_500)

      rendered = Summary.render([message(content: long)])

      assert String.ends_with?(rendered, "…")
      assert String.length(rendered) == String.length("user: ") + 2_000 + 1
    end

    test "leaves a message at the cap alone" do
      exact = String.duplicate("a", 2_000)

      refute Summary.render([message(content: exact)]) =~ "…"
    end

    test "is empty for no messages" do
      assert Summary.render([]) == ""
    end
  end

  describe "request/1" do
    test "carries the system prompt, the history and the reply schema" do
      request = Summary.request([message(content: "I use Elixir.")])

      assert request.system == Summary.system_prompt()
      assert request.messages == [%{role: :user, content: "user: I use Elixir."}]
      assert request.schema["required"] == ["summary"]
      assert request.schema["properties"]["summary"]["type"] == "string"
      assert request.schema["additionalProperties"] == false
    end
  end

  describe "decode/4" do
    test "builds the summary in the scope given, stamped and watermarked" do
      scope = scope(app_id: "widget")

      assert {:ok, summary} =
               Summary.decode(~s({"summary": "The user uses Elixir."}), scope, at(10), 42)

      assert summary.scope == scope
      assert summary.text == "The user uses Elixir."
      assert summary.generated_at == at(10)
      assert summary.through_seq == 42
    end

    test "trims the text" do
      reply = ~s({"summary": "  The user uses Elixir.\\n  "})

      assert {:ok, summary} = Summary.decode(reply, scope(), at(0), 1)
      assert summary.text == "The user uses Elixir."
    end

    for {name, reply} <- [
          {"a reply that is not JSON at all", "Here is the summary you asked for!"},
          {"a reply that is truncated JSON", ~s({"summary": "The us)},
          {"JSON with no summary key", ~s({"digest": "The user uses Elixir."})},
          {"a summary that is not a string", ~s({"summary": ["The user uses Elixir."]})},
          {"a summary that is null", ~s({"summary": null})},
          {"a bare JSON string", ~s("The user uses Elixir.")},
          {"a blank summary", ~s({"summary": ""})},
          {"a summary that is blank once trimmed", ~s({"summary": "  \\n  "})},
          {"an empty reply", ""}
        ] do
      test "#{name} is malformed rather than a raise" do
        assert Summary.decode(unquote(reply), scope(), at(0), 1) ==
                 {:error, :malformed_summary}
      end
    end
  end
end
