defmodule Mem0Web.TranscriptController do
  @moduledoc """
  Ingests a whole transcript file in one request. The single capture
  endpoint: the hook script posts here on `Stop` and `SessionEnd`, and an
  operator posts here to backfill a file by hand.

  Synchronous and honest — 422 for a body that is not JSON Lines, 413 for
  one too large — because both callers can afford to wait and re-posting is
  always safe: the message store dedups what it has already seen and the
  processor's watermark refuses what it has already read.
  """

  use Mem0Web, :controller

  alias Mem0.Importer
  alias Mem0.Ingester.Claude

  # A whole transcript held in memory at once; past this the request is
  # refused rather than the VM grown without bound.
  @max_transcript_bytes 50_000_000

  @doc """
  Accepts a whole transcript file as raw JSON Lines.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    with {:ok, body} <- fetch_body(conn, @max_transcript_bytes),
         {:ok, scope, messages} <- Importer.import_transcript(body, Claude) do
      render(conn, :create, messages: messages, session: scope)
    else
      {:error, :transcript_exceeds_size} ->
        error(conn, 413, "transcript exceeds #{@max_transcript_bytes} bytes")

      {:error, :failed_to_read_transcript} ->
        error(conn, 400, "could not read the request body")
      {:error, _err} ->
        error(conn, 500, "could not import transcript")
    end
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # fetch the body and limit the maximum size. error if it's too big.
  defp fetch_body(conn, limit) do
    case read_body(conn, length: limit) do
      {:ok, raw, _conn} ->
        {:ok, raw}

      {:more, _chunk, _conn} ->
        {:error, :transcript_exceeds_size}

      {:error, _reason} ->
        {:error, :failed_to_read_transcript}
    end
  end

  @spec error(Plug.Conn.t(), pos_integer(), String.t()) :: Plug.Conn.t()
  defp error(conn, status, message) do
    conn
    |> put_status(status)
    |> render(:error, message: message)
  end
end
