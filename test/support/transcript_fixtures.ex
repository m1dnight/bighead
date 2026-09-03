defmodule Bighead.TranscriptFixtures do
  @moduledoc """
  Loads the captured transcript fixtures in `test/support/fixtures/transcripts`.

  After the normaliser itself these files are this phase's most valuable
  artifact: they are the record of a format nobody controls, and the only thing
  that will tell us it moved. See the README beside them for what each one
  captures and how to add another.
  """

  @dir Path.join(__DIR__, "fixtures/transcripts")

  @doc "A fixture as the raw JSON Lines string it sits on disk as."
  @spec raw(String.t()) :: String.t()
  def raw(name) do
    @dir
    |> Path.join(name <> ".jsonl")
    |> File.read!()
  end

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
  end
end
