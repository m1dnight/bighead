defmodule Bighead.Extractor.PromptTest do
  @moduledoc """
  The extraction prompt: the conversation renders as `role: content` lines
  under the summary, and the system prompt carries the extraction rules.
  """
  use ExUnit.Case, async: true

  alias Bighead.Extractor.Prompt

  describe "render/1" do
    test "renders each message as a role: content line, in order" do
      rendered =
        Prompt.render(
          summary: "so far: build talk",
          messages: [
            %{role: "user", content: "I prefer Elixir"},
            %{role: "assistant", content: "Noted."}
          ]
        )

      assert rendered =~ "so far: build talk"
      assert rendered =~ "user: I prefer Elixir"
      assert rendered =~ "assistant: Noted."

      assert first_index(rendered, "user:") < first_index(rendered, "assistant:")
    end

    test "a nil summary renders as nothing rather than crashing" do
      rendered = Prompt.render(summary: nil, messages: [%{role: "user", content: "hi"}])

      assert rendered =~ "user: hi"
    end
  end

  describe "system_prompt/0" do
    test "carries the extraction instructions" do
      assert Prompt.system_prompt() =~ "durable facts"
      assert Prompt.system_prompt() =~ "empty list"
    end
  end

  defp first_index(string, part) do
    {index, _length} = :binary.match(string, part)
    index
  end
end
