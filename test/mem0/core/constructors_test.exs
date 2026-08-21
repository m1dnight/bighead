defmodule Mem0.Core.ConstructorsTest do
  @moduledoc """
  `typed_struct` generates no constructor, so every module hand-writes `new/1`.
  These tests are the guarantee that a half-built struct is unconstructible —
  the guarantee that stops a nil check appearing in every function downstream.
  """
  use ExUnit.Case, async: true
  use Mem0.CoreFixtures

  describe "required keys" do
    test "a missing key raises rather than defaulting to nil" do
      for {module, fields} <- [
            {Message, message_fields()},
            {Summary, summary_fields()},
            {Prompt, prompt_fields()},
            {Fact, fact_fields()},
            {Extraction, extraction_fields()},
            {Memory, memory_fields()},
            {Decision, decision_fields()}
          ],
          dropped <- required_keys(module) do
        remaining = Keyword.delete(fields, dropped)

        assert_raise ArgumentError, fn -> module.new(remaining) end
      end
    end

    test "the fixtures themselves build" do
      assert %Message{} = message()
      assert %Summary{} = summary()
      assert %Prompt{} = prompt()
      assert %Fact{} = fact()
      assert %Extraction{} = extraction()
      assert %Memory{} = memory()
      assert %Decision{} = decision()
    end
  end

  describe "optional fields" do
    test "an unstated event time is nil, never the utterance time" do
      assert %Fact{event_time: nil} = Fact.new(content: "c", scope: scope(), extracted_at: at(0))
    end

    test "an unstated summary is nil, because a new conversation has no S yet" do
      fields = prompt_fields() |> Keyword.delete(:summary)

      assert %Prompt{summary: nil} = Prompt.new(fields)
    end

    test "list fields default to empty" do
      assert %Fact{source_message_ids: []} =
               Fact.new(content: "c", scope: scope(), extracted_at: at(0))

      assert %Extraction{facts: [], source_message_ids: []} =
               Extraction.new(scope: scope(), prompt_at: at(0))
    end
  end

  # Required means `@enforce_keys`, which is what a block-level `enforce: true`
  # produces for every field that does not carry a `default:`.
  defp required_keys(module) do
    for %{field: field, required: true} <- List.wrap(module.__info__(:struct)), do: field
  end
end
