defmodule Mem0.Ingester.Codex do
  @moduledoc """
  Ingests JSON entries form transcripts in a Codex chat, and converts them to
  `Message`s.
  """

  @behaviour Mem0.Ingester

  alias Mem0.Ingester.Decoder
  alias Mem0.Ingester.Message

  @impl true
  # a user message in a response_item is kept.
  def skip_entry?(%{
        "type" => "response_item",
        "payload" => %{"type" => "message", "role" => "user"}
      }) do
    false
  end

  # an assistant message is only kept when it is the final answer, not a
  # draft phase.
  def skip_entry?(%{
        "type" => "response_item",
        "payload" => %{"type" => "message", "role" => "assistant", "phase" => "final_answer"}
      }) do
    false
  end

  # everything else (reasoning, function calls, other event types) is ignored.
  def skip_entry?(_entry) do
    true
  end

  # Converts a raw entry from a Codex log into a Message struct.
  @impl true
  def parse_entry(%{"type" => "response_item"} = entry) when is_map(entry) do
    with {:ok, payload} <- Map.fetch(entry, "payload"),
         {:ok, timestamp} <- Map.fetch(entry, "timestamp"),
         {:ok, timestamp, _} <- DateTime.from_iso8601(timestamp),
         id = Map.get(payload, "id"),
         {:ok, role} <- Map.fetch(payload, "role"),
         {:ok, contents} <- Map.fetch(payload, "content") do
      content = Decoder.decode_contents(contents)

      {:ok,
       %Message{
         id: id,
         role: role,
         content: content,
         timestamp: timestamp
       }}
    else
      _ ->
        {:error, :decode_failed}
    end
  end

  def parse_entry(_) do
    {:error, :decode_failed}
  end

  # for codex, we rely on the specific entry that contains meta information
  # about the transcript.
  @impl true
  def scope(entries) do
    entries
    |> Enum.reduce([], fn entry, scope ->
      case entry do
        %{"type" => "session_meta"} ->
          git = get_in(entry, ["payload", "git", "repository_url"])
          cwd = get_in(entry, ["payload", "cwd"])
          session = get_in(entry, ["payload", "id"])
          [{git || cwd, session}] ++ scope

        _ ->
          scope
      end
    end)
    |> Enum.sort()
    |> Enum.dedup()
    |> case do
      [] ->
        {:error, :no_project}

      [{_project, nil}] ->
        {:error, :no_session_found}

      [{project, session}] ->
        {:ok, %{project: project, session: session}}

      _ ->
        {:error, :ambiguous_scope}
    end
  end
end
