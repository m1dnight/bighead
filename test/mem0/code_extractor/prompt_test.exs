defmodule Bighead.CodeExtractor.PromptTest do
  @moduledoc """
  The code-extraction prompt: each diff renders under its file name and
  origin, in the order given, and the system prompt carries the rules.
  """
  use ExUnit.Case, async: true

  alias Bighead.CodeExtractor.Prompt

  describe "render/1" do
    test "renders every diff with its file name and origin, in order" do
      rendered =
        Prompt.render(
          diffs: [
            %{file: "lib/foo.ex", origin: :requested, diff: "@@ -1 +1 @@\n-old()\n+new()"},
            %{file: "lib/bar.ex", origin: :manual, diff: "@@ -2 +2 @@\n-a()\n+b()"}
          ]
        )

      assert rendered =~ "file: lib/foo.ex\nchange: requested"
      assert rendered =~ "file: lib/bar.ex\nchange: manual"
      assert rendered =~ "+new()"
      assert rendered =~ "+b()"

      assert first_index(rendered, "lib/foo.ex") < first_index(rendered, "+new()")
      assert first_index(rendered, "+new()") < first_index(rendered, "lib/bar.ex")
    end

    test "a diff without an origin renders as unknown" do
      rendered = Prompt.render(diffs: [%{file: "lib/foo.ex", origin: nil, diff: "@@ -1 +1 @@"}])

      assert rendered =~ "change: unknown"
    end
  end

  describe "system_prompt/0" do
    test "carries the extraction instructions" do
      assert Prompt.system_prompt() =~ "git diff"
      assert Prompt.system_prompt() =~ "empty list"
    end
  end

  defp first_index(string, part) do
    {index, _length} = :binary.match(string, part)
    index
  end
end
