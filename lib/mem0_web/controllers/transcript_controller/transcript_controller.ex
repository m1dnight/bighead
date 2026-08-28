defmodule Mem0Web.TranscriptController do
  @moduledoc """
  Ingests a whole transcript file in one request — an operator's tool, not a
  Claude Code hook.

  That distinction is the posture: the hook routes answer 200 whatever
  arrives because a live session blocks on the reply, while here only the
  person who posted the file waits, so it answers honestly — 422 for a body
  that is not JSON Lines, 413 for one too large — and does its work
  synchronously so the reply can say what happened.
  """

  use Mem0Web, :controller

  alias Mem0.Ingest
  alias Mem0.Messages
  alias Mem0.Reconcile
  alias Mem0.Summarize

  # A whole transcript held in memory at once; past this the request is
  # refused rather than the VM grown without bound.
  @max_transcript_bytes 50_000_000

  @doc """
  Accepts a whole transcript file as raw JSON Lines and runs the full write
  path over it: messages stored, summary refresh kicked off, and one
  synchronous pulse — facts extracted past the cursor and reconciled into
  memories. Backfill and `Stop` in one request:

      curl -X POST -H 'content-type: application/jsonl' \\
        --data-binary @session.jsonl http://localhost:4000/transcripts

  The scope comes from the file's own `sessionId` and `cwd`; `session_id`
  and `cwd` query parameters override them. Posting the same file twice is
  safe — the message store dedups on id and the cursor refuses what it has
  already read.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    case read_transcript(conn, [], 0) do
      {:ok, raw, conn} ->
        ingest_transcript(conn, raw, params)

      {:too_large, conn} ->
        error(conn, 413, "transcript exceeds #{@max_transcript_bytes} bytes")

      {:error, _reason} ->
        error(conn, 400, "could not read the request body")
    end
  end

  @spec ingest_transcript(Plug.Conn.t(), binary(), map()) :: Plug.Conn.t()
  defp ingest_transcript(conn, raw, params) do
    with {:ok, scope, messages, drops} <-
           Ingest.receive_transcript(raw, params, Ingest.default_user_id()),
         {:ok, stored} <- Messages.put(messages) do
      Summarize.refresh_async(scope)
      result = Reconcile.pulse(scope)

      json(conn, %{stored: stored, dropped: length(drops), pulse: pulse_summary(result)})
    else
      {:error, {:invalid_line, number}} ->
        error(conn, 422, "line #{number} is not JSON")

      {:error, exception} when is_exception(exception) ->
        error(conn, 503, "storage unavailable")

      {:error, _reason} ->
        error(conn, 422, "not a transcript")
    end
  end

  @spec read_transcript(Plug.Conn.t(), [binary()], non_neg_integer()) ::
          {:ok, binary(), Plug.Conn.t()} | {:too_large, Plug.Conn.t()} | {:error, term()}
  defp read_transcript(conn, chunks, bytes) when bytes <= @max_transcript_bytes do
    case read_body(conn, length: 8_000_000) do
      {:ok, chunk, conn} when bytes + byte_size(chunk) <= @max_transcript_bytes ->
        {:ok, IO.iodata_to_binary(Enum.reverse([chunk | chunks])), conn}

      {:ok, _chunk, conn} ->
        {:too_large, conn}

      {:more, chunk, conn} ->
        read_transcript(conn, [chunk | chunks], bytes + byte_size(chunk))

      {:error, _reason} = failure ->
        failure
    end
  end

  defp read_transcript(conn, _chunks, _bytes), do: {:too_large, conn}

  @spec error(Plug.Conn.t(), pos_integer(), String.t()) :: Plug.Conn.t()
  defp error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end

  # Counts and verbs, no content — what the pulse did, not what it read.
  @spec pulse_summary({:ok, [map()]} | :nothing_new | {:error, term()}) :: map()
  defp pulse_summary({:ok, decisions}) do
    %{
      outcome: "reconciled",
      facts: length(decisions),
      operations: Enum.frequencies_by(decisions, &verb(&1.operation))
    }
  end

  defp pulse_summary(:nothing_new), do: %{outcome: "nothing_new"}
  defp pulse_summary({:error, reason}), do: %{outcome: "error", reason: error_tag(reason)}

  @spec verb(tuple() | :noop) :: String.t()
  defp verb({:add, _fact}), do: "add"
  defp verb({:update, _id, _fact}), do: "update"
  defp verb({:delete, _id}), do: "delete"
  defp verb(:noop), do: "noop"

  # The reason's leading tag only: an LLM error term can carry a response
  # body, and this reply should say what kind of failure, not relay it.
  @spec error_tag(term()) :: String.t()
  defp error_tag(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_tag(%module{}), do: inspect(module)

  defp error_tag(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: Atom.to_string(elem(reason, 0))

  defp error_tag(_reason), do: "unknown"
end
