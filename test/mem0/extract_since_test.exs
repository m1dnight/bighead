defmodule Mem0.ExtractSinceTest do
  @moduledoc """
  The wiring, not the call: `facts_since/3` is `Prompt.from_history/1`
  composed with both stores and the port, and this is the first extraction
  suite that needs all three at once. What it checks is that the assembled
  request carries what the stores hold — the summary's text, the split at the
  watermark — and that the `:nothing_new` paths spend nothing.
  """
  use Mem0.DataCase, async: true
  use Mem0.CoreFixtures

  alias Mem0.Extract
  alias Mem0.LLM
  alias Mem0.Messages
  alias Mem0.Summaries

  setup do
    LLM.Stub.start!(reply: {:ok, LLM.Stub.response(~s({"facts": ["Uses Elixir"]}))})
    :ok
  end

  test "the stored summary and the split ride the request where render/1 says" do
    scope = scope()
    store(scope, 1..15)
    :ok = Summaries.put(summary(scope: scope, text: "The user uses Elixir.", through_seq: 12))

    assert {:ok, extraction} = Extract.facts_since(scope, 13)

    assert [request] = LLM.Stub.calls()
    assert [%{content: content}] = request.messages
    assert content =~ "# Conversation summary\nThe user uses Elixir."
    assert content =~ "# Earlier messages (context)\nuser: message 1"

    assert content =~
             "# New messages (extract from these only)\nuser: message 14\n\nuser: message 15"

    # Provenance follows the split: the context that rode along is not a source.
    assert extraction.source_message_ids == ["msg-14", "msg-15"]
  end

  test "a run with no stored summary sends no summary section" do
    scope = scope()
    store(scope, 1..3)

    assert {:ok, _extraction} = Extract.facts_since(scope, nil)

    assert [request] = LLM.Stub.calls()
    assert [%{content: content}] = request.messages
    refute content =~ "# Conversation summary"
    refute content =~ "# Earlier messages"
    assert content =~ "# New messages (extract from these only)\nuser: message 1"
  end

  test "a watermark at the head is :nothing_new and spends no call" do
    scope = scope()
    store(scope, 1..5)

    assert Extract.facts_since(scope, 5) == {:error, :nothing_new}
    assert LLM.Stub.calls() == []
  end

  test "an empty run is :nothing_new and spends no call" do
    assert Extract.facts_since(scope(), nil) == {:error, :nothing_new}
    assert LLM.Stub.calls() == []
  end

  defp store(scope, seqs) do
    {:ok, _count} =
      Messages.put(
        for seq <- seqs,
            do: message(id: "msg-#{seq}", scope: scope, content: "message #{seq}", seq: seq)
      )
  end
end
