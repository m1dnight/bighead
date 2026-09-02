defmodule Mem0Web.DiffController do
  @moduledoc """
  Accepts a code diff for one file and stores it.

  Same posture as `Mem0Web.TranscriptController`: the submitter waits for the
  reply, so it answers honestly — 422 for a payload that is not the expected
  shape — rather than the always-200 the hook routes owe a blocked session.
  """

  use Mem0Web, :controller

  alias Mem0.Store.Diffs

  defdelegate open_api_operation(action), to: Mem0Web.DiffApiSpec

  @doc """
  Stores one diff.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"file" => file, "diff" => diff}) when is_binary(file) and is_binary(diff) do
    case Diffs.create(%{file: file, diff: diff}) do
      {:ok, stored} ->
        render(conn, :create, diff: stored)

      {:error, _changeset} ->
        invalid_payload(conn)
    end
  end

  def create(conn, _params) do
    invalid_payload(conn)
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  @spec invalid_payload(Plug.Conn.t()) :: Plug.Conn.t()
  defp invalid_payload(conn) do
    conn
    |> put_status(422)
    |> render(:error)
  end
end
