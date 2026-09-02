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
    with :ok <- refuse_blank([file, diff, project, session]),
         {:ok, scope} <- Scopes.create(%{user: "default", project: project, session: session}),
         {:ok, stored} <- Diffs.create(%{file: file, diff: diff, scope_id: scope.id}) do
      IO.puts("Got some diffs yo")
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

  # The scope is created before the diff is validated, so a blank value in
  # any field is refused up front rather than leaving a junk scope behind a
  # 422. The scope changeset itself only requires a user.
  @spec refuse_blank([String.t()]) :: :ok | {:error, :blank_value}
  defp refuse_blank(values) do
    if Enum.any?(values, &(String.trim(&1) == "")), do: {:error, :blank_value}, else: :ok
  end

  @spec invalid_payload(Plug.Conn.t()) :: Plug.Conn.t()
  defp invalid_payload(conn) do
    conn
    |> put_status(422)
    |> render(:error)
  end
end
