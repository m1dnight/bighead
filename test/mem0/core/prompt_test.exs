defmodule Mem0.Core.PromptTest do
  @moduledoc """
  The one place the recent/new split lives. The interesting inputs are the
  awkward ones: gapped seqs, shuffled lists, watermarks at or past the head —
  each has to land on either a well-formed split or `:nothing_new`, never on a
  prompt with nothing to extract from.
  """
  use ExUnit.Case, async: true
  use Mem0.CoreFixtures

  doctest Prompt

  describe "from_history/1" do
    test "splits at the watermark: past it is new, the rest is recent" do
      {:ok, prompt} = Prompt.from_history(messages: gapped(), last_message_seq: 3)

      assert Enum.map(prompt.recent, & &1.seq) == [3]
      assert Enum.map(prompt.new, & &1.seq) == [17, 40]
    end

    test "the split compares seqs, not positions, so gaps do not shift it" do
      {:ok, prompt} = Prompt.from_history(messages: gapped(), last_message_seq: 20)

      assert Enum.map(prompt.recent, & &1.seq) == [3, 17]
      assert Enum.map(prompt.new, & &1.seq) == [40]
    end

    test "a nil last_message_seq means no watermark: everything is new" do
      {:ok, prompt} = Prompt.from_history(messages: gapped(), last_message_seq: nil)

      assert prompt.recent == []
      assert Enum.map(prompt.new, & &1.seq) == [3, 17, 40]
    end

    test "a watermark at the head is :nothing_new" do
      assert Prompt.from_history(messages: gapped(), last_message_seq: 40) ==
               {:error, :nothing_new}
    end

    test "a watermark past the head is :nothing_new" do
      assert Prompt.from_history(messages: gapped(), last_message_seq: 99) ==
               {:error, :nothing_new}
    end

    test "an empty run is :nothing_new" do
      assert Prompt.from_history(messages: [], last_message_seq: nil) == {:error, :nothing_new}
    end

    test "sorts shuffled input, so both slices come out in seq order" do
      shuffled = [numbered(40), numbered(3), numbered(17)]

      {:ok, prompt} = Prompt.from_history(messages: shuffled, last_message_seq: 3)

      assert Enum.map(prompt.recent, & &1.seq) == [3]
      assert Enum.map(prompt.new, & &1.seq) == [17, 40]
    end

    test "carries the summary it is given" do
      summary = summary(text: "The user uses Elixir.")

      {:ok, prompt} =
        Prompt.from_history(messages: gapped(), last_message_seq: nil, summary: summary)

      assert prompt.summary == summary
    end

    test "no summary defaults to nil, because a young run has no S yet" do
      {:ok, prompt} = Prompt.from_history(messages: gapped(), last_message_seq: nil)

      assert prompt.summary == nil
    end

    test "takes the scope from the messages" do
      scope = scope(app_id: "widget")
      messages = [message(id: "m-1", scope: scope, seq: 1)]

      {:ok, prompt} = Prompt.from_history(messages: messages, last_message_seq: nil)

      assert prompt.scope == scope
    end
  end

  defp gapped, do: Enum.map([3, 17, 40], &numbered/1)

  defp numbered(seq), do: message(id: "m-#{seq}", content: "message #{seq}", seq: seq)
end
