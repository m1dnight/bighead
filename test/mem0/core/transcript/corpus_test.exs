defmodule Mem0.Core.Transcript.CorpusTest do
  @moduledoc """
  Runs the normaliser over every Claude Code transcript on this machine.

  The wrapper allow-list is the one rule that can discard something a person
  really typed: widen it by one careless tag and real prompts start vanishing,
  silently and only for the sessions that happen to contain it. Fixtures cannot
  catch that, because a fixture only knows the shapes we thought to capture.
  The corpus can, and it grows on its own.

  `@tag :corpus` and excluded by default: it depends on machine-local files, so
  it is a check you run, not one CI can. `mix test --include corpus`.
  """
  use ExUnit.Case, async: true
  use Mem0.CoreFixtures

  alias Mem0.Core.Transcript.ClaudeCode

  @moduletag :corpus

  @projects Path.expand("~/.claude/projects")

  setup_all do
    entries =
      @projects
      |> Path.join("**/*.jsonl")
      |> Path.wildcard()
      |> Enum.flat_map(&decode/1)

    # A corpus test that passes because it found nothing is not a test.
    assert length(entries) > 100

    {:ok, entries: entries}
  end

  test "no entry a person authored is ever dropped as synthetic", %{entries: entries} do
    human = Enum.filter(entries, &match?(%{"origin" => %{"kind" => "human"}}, &1))

    refute Enum.empty?(human)

    # One entry per batch, so a drop can be attributed to the entry that caused
    # it — `messages/3` reports drops for a batch, not per entry.
    eaten =
      for entry <- human,
          {[], [:synthetic]} <- [ClaudeCode.messages([entry], scope())],
          do: entry["uuid"]

    assert [] == eaten
  end

  test "the parse is total over every entry in the corpus", %{entries: entries} do
    assert {messages, drops} = ClaudeCode.messages(entries, scope())
    assert length(messages) + length(drops) == length(entries)
  end

  test "no tool result is ever ingested as a message", %{entries: entries} do
    tool_results =
      Enum.filter(entries, fn entry ->
        content = get_in(entry, ["message", "content"])

        is_list(content) and
          Enum.any?(content, &match?(%{"type" => "tool_result"}, &1))
      end)

    refute Enum.empty?(tool_results)
    assert {[], drops} = ClaudeCode.messages(tool_results, scope())

    # `:sidechain` appears alongside `:tool_result` because rule 3 runs first: a
    # subagent's tool results are rejected for being a subagent's. Which reason
    # won does not matter here — that none of them became a message does.
    assert [] == Enum.uniq(drops) -- [:tool_result, :sidechain]
  end

  defp decode(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, entry} when is_map(entry) -> [entry]
        _not_an_object -> []
      end
    end)
  end
end
