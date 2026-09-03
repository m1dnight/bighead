defmodule Bighead.Reconciler.PromptTest do
  @moduledoc """
  The reconciliation prompt: stored memories render as `id: fact` lines, the
  candidate fact renders under them, and the system prompt carries the
  decision rules.
  """
  use ExUnit.Case, async: true

  alias Bighead.Reconciler.Prompt

  describe "render/1" do
    test "renders the known facts by id and the new fact after them" do
      rendered =
        Prompt.render(
          fact: "Prefers Neovim",
          facts: [%{id: 1, fact: "Uses Vim"}, %{id: 2, fact: "Works on bighead"}]
        )

      assert rendered =~ "1: Uses Vim"
      assert rendered =~ "2: Works on bighead"
      assert rendered =~ "Prefers Neovim"
    end

    test "no known facts still renders the new fact" do
      rendered = Prompt.render(fact: "Prefers Neovim", facts: [])

      assert rendered =~ "Prefers Neovim"
    end
  end

  describe "system_prompt/0" do
    test "carries the four verdicts the schema allows" do
      for verdict <- ["ADD", "UPDATE", "DELETE", "NOOP"] do
        assert Prompt.system_prompt() =~ verdict
      end
    end
  end
end
