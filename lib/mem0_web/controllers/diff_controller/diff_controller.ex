defmodule Mem0Web.DiffController do
  @moduledoc """
  Accepts a code diff for one file and stores it.

  Same posture as `Mem0Web.TranscriptController`: the submitter waits for the
  reply, so it answers honestly — 422 for a payload that is not the expected
  shape — rather than the always-200 the hook routes owe a blocked session.
  """

  use Mem0Web, :controller

  alias Mem0.Store.Diffs

  @doc """
  Stores one diff:

      curl -X POST -H 'content-type: application/json' \\
        -d '{"file": "lib/foo.ex", "diff": "@@ -1 +1 @@..."}' \\
        http://localhost:4000/diffs

  Posting the same payload twice is safe — the store dedups on file and diff
  text, and the reply carries the existing row's id.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"file" => file, "diff" => diff}) when is_binary(file) and is_binary(diff) do
    case Diffs.create(%{file: file, diff: diff}) do
      {:ok, stored} ->
        json(conn, %{id: stored.id, file: stored.file})

      # The guard already ensured both fields are binaries, so this is a
      # blank file or diff — a shape problem, same answer as the clause below.
      {:error, _changeset} ->
        invalid_payload(conn)
    end
  end

  def create(conn, _params), do: invalid_payload(conn)

  @spec invalid_payload(Plug.Conn.t()) :: Plug.Conn.t()
  defp invalid_payload(conn) do
    conn
    |> put_status(422)
    |> json(%{error: ~s(expected {"file": <path>, "diff": <diff text>})})
  end
end
