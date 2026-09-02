defmodule Mem0Web.DiffController do
  @moduledoc """
  Accepts a code diff for one file and stores it under the scope of the
  session it happened in.

  Same posture as `Mem0Web.TranscriptController`: the submitter waits for the
  reply, so it answers honestly — 422 for a payload that is not the expected
  shape — rather than the always-200 the hook routes owe a blocked session.
  """

  use Mem0Web, :controller

  alias Mem0.Refresher
  alias Mem0.Store.Diffs
  alias Mem0.Store.Scope
  alias Mem0.Store.Scopes

  defdelegate open_api_operation(action), to: Mem0Web.DiffApiSpec

  @doc """
  Stores one diff.

  `project` and `session` name the scope, the same `(cwd, session id)` pair
  the transcript path resolves to, so a diff and the conversation it came
  from land on the same scope row.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"file" => file, "diff" => diff, "project" => project, "session" => session})
      when is_binary(file) and is_binary(diff) and is_binary(project) and is_binary(session) do
    with {:ok, scope} <- scope(project, session),
         {:ok, stored} <- Diffs.create(%{file: file, diff: diff, scope_id: scope.id}) do
      # Fire-and-forget, as on the transcript route: extraction happens off
      # the request path, and a cast to a refresher that is not running
      # (test) is a silent no-op.
      Refresher.poke()

      render(conn, :create, diff: stored)
    else
      {:error, _reason} ->
        invalid_payload(conn)
    end
  end

  def create(conn, _params) do
    invalid_payload(conn)
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # The scope changeset only requires a user, so blank project or session
  # values are refused here rather than stored as a junk scope.
  @spec scope(String.t(), String.t()) ::
          {:ok, Scope.t()} | {:error, :blank_scope | Ecto.Changeset.t()}
  defp scope(project, session) do
    if String.trim(project) == "" or String.trim(session) == "" do
      {:error, :blank_scope}
    else
      Scopes.create(%{user: "default", project: project, session: session})
    end
  end

  @spec invalid_payload(Plug.Conn.t()) :: Plug.Conn.t()
  defp invalid_payload(conn) do
    conn
    |> put_status(422)
    |> render(:error)
  end
end
