defmodule BigheadWeb.DiffController do
  @moduledoc """
  Accepts a code diff for one file and stores it under the scope of the
  session it happened in.

  Same posture as `BigheadWeb.TranscriptController`: the submitter waits for the
  reply, so it answers honestly — 422 for a payload that is not the expected
  shape — rather than the always-200 the hook routes owe a blocked session.
  """

  use BigheadWeb, :controller

  alias Bighead.Refresher
  alias Bighead.Store.Diffs
  alias Bighead.Store.Scopes

  defdelegate open_api_operation(action), to: BigheadWeb.DiffApiSpec

  @doc """
  Stores one diff.

  `project` and `session` name the scope, the same `(cwd, session id)` pair
  the transcript path resolves to, so a diff and the conversation it came
  from land on the same scope row. `origin` says how the change came about:
  `manual` for a hand edit of the agent's code, `own` for a hand edit of code
  the agent had not touched, `requested` for the agent changing its own code
  on the developer's prompt, `agent` for the agent's own work on the
  developer's code.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"file" => file, "diff" => diff, "project" => project, "session" => session, "origin" => origin})
      when is_binary(file) and is_binary(diff) and is_binary(project) and is_binary(session) do
    with {:ok, origin} <- origin(origin),
         :ok <- refuse_blank([file, diff, project, session]),
         {:ok, scope} <- Scopes.create(%{user: "default", project: project, session: session}),
         {:ok, stored} <-
           Diffs.create(%{file: file, diff: diff, origin: origin, scope_id: scope.id}) do
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

  # How the change came about. A fixed mapping, so no client string ever
  # becomes an atom.
  @spec origin(term()) :: {:ok, :manual | :own | :requested | :agent} | {:error, :unknown_origin}
  defp origin("manual"), do: {:ok, :manual}
  defp origin("own"), do: {:ok, :own}
  defp origin("requested"), do: {:ok, :requested}
  defp origin("agent"), do: {:ok, :agent}
  defp origin(_other), do: {:error, :unknown_origin}

  @spec invalid_payload(Plug.Conn.t()) :: Plug.Conn.t()
  defp invalid_payload(conn) do
    conn
    |> put_status(422)
    |> render(:error)
  end
end
