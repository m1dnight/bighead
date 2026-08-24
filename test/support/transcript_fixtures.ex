defmodule Mem0.TranscriptFixtures do
  @moduledoc """
  Loads the captured transcript fixtures in `test/support/fixtures/transcripts`.

  After the normaliser itself these files are this phase's most valuable
  artifact: they are the record of a format nobody controls, and the only thing
  that will tell us it moved. See the README beside them for what each one
  captures and how to add another.
  """

  @dir Path.join(__DIR__, "fixtures/transcripts")

  @doc "Every entry of a fixture, decoded, in file order."
  @spec entries(String.t()) :: [map()]
  def entries(name) do
    @dir
    |> Path.join(name <> ".jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  @doc "Every fixture's name."
  @spec names() :: [String.t()]
  def names do
    @dir
    |> Path.join("*.jsonl")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".jsonl"))
    |> Enum.sort()
  end

  @doc """
  A `Stop` hook payload carrying `entries`, shaped the way `stop.sh` shapes it.

  `offset` is how many transcript lines precede this batch, so the payload's two
  counts are consistent with a tail slice taken that far into a run.

  `last_assistant_message`, `prompt_id` and `hook_at` are what the boundary
  rebuilds the turn's answer from — the entry Claude Code has not flushed yet.
  They default to absent, because most tests are about the transcript rather
  than about that reconstruction; pass them to exercise it.
  """
  @spec stop_payload([map()], keyword()) :: map()
  def stop_payload(entries, opts \\ []) do
    offset = Keyword.get(opts, :offset, 0)
    first = List.first(entries) || %{}

    %{
      "hook_event_name" => "Stop",
      "session_id" => Keyword.get(opts, :session_id, Map.get(first, "sessionId", "session-1")),
      "cwd" => Keyword.get(opts, :cwd, Map.get(first, "cwd", "/Users/example/Code/widget")),
      "transcript_path" => "/Users/example/.claude/projects/example/session.jsonl",
      "stop_hook_active" => false,
      "entries" => entries,
      "transcript_length" => length(entries),
      "total_transcript_length" => offset + length(entries)
    }
    |> put_present("last_assistant_message", Keyword.get(opts, :last_assistant_message))
    |> put_present("prompt_id", Keyword.get(opts, :prompt_id, "prompt-1"))
    |> put_present("hook_at", Keyword.get(opts, :hook_at, "2026-08-24T15:12:56Z"))
  end

  defp put_present(payload, _key, nil), do: payload
  defp put_present(payload, key, value), do: Map.put(payload, key, value)
end
