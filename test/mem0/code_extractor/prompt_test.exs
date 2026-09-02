defmodule Mem0.CodeExtractor.PromptTest do
  @moduledoc """
  The code-extraction prompt: the diff renders under its file name, and the
  system prompt carries the extraction rules.
  """
  use ExUnit.Case, async: true

  alias Mem0.CodeExtractor.Prompt

  describe "render/1" do
    test "renders the file name and origin followed by the diff text" do
      rendered =
        Prompt.render(
          file: "lib/foo.ex",
          diff: "@@ -1 +1 @@\n-old_line()\n+new_line()",
          origin: :requested
        )

      assert rendered =~ "file: lib/foo.ex"
      assert rendered =~ "change: requested"
      assert rendered =~ "-old_line()"
      assert rendered =~ "+new_line()"

      assert first_index(rendered, "lib/foo.ex") < first_index(rendered, "@@")
    end

    test "a diff without an origin renders as unknown" do
      assert Prompt.render(file: "lib/foo.ex", diff: "@@ -1 +1 @@") =~ "change: unknown"
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
