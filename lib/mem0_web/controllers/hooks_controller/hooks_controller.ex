defmodule Mem0Web.HooksController do
  @moduledoc """
  Controller for the Claude Code hooks mem0 listens on.
  """
  use Mem0Web, :controller

  alias Mem0.Ingest
  alias Mem0.Messages
  alias Mem0.Reconcile
  alias Mem0.Summarize
  alias Mem0Web.HookResponse

  # Recall lands here. Empty until there is something to recall.
  @additional_context ""

  @doc """
  `UserPromptSubmit`. Answers with recalled context; ingests nothing.
  """
  @spec user_prompt_submit(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def user_prompt_submit(conn, params) do
    title = params |> Map.get("prompt") |> session_title()

    json(conn, HookResponse.user_prompt_submit(@additional_context, title))
  end

  @doc """
  `Stop` is called when the agent was done replying.

  When the hook calls this endpoint, it means the LLM replied. We have to check
  if the summary needs to be updated.

  Example payload:

  ```
    %{
      "background_tasks" => [],
      "cwd" => "/path/to/dir",
      "effort" => %{"level" => "low"},
      "hook_event_name" => "Stop",
      "last_assistant_message" => "I'm Claude.",
      "permission_mode" => "auto",
      "prompt_id" => "f92a0650-4680-43e3-84e5-227ccd1e680a",
      "session_crons" => [],
      "session_id" => "875d9818-ab37-4aaf-aeac-0a2846670fd2",
      "stop_hook_active" => false,
      "transcript_path" => "/transcript/path/file.jsonl"
    }
  ```
  """
  @spec stop(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def stop(conn, params) do
    scope = Ingest.scope(params, Ingest.default_user_id())

    # Both run off the request path — Claude Code is blocked on this reply.
    # Their race is benign: if the refresh and the pulse interleave,
    # extraction reads the previous summary, which is context, not
    # provenance, and the new messages are in the prompt regardless.
    Summarize.refresh_async(scope)
    Reconcile.pulse_async(scope)

    json(conn, HookResponse.stop())
  end

  @doc """
  A hook file can read a whole transcript and backfill the lines here in chunks.

  When the script is called, the script could be several hundred lines, and we
  want to avoid POSTing a huge file each time.
  """
  @spec backfill(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def backfill(conn, params) do
    stored =
      params
      |> Ingest.receive(Ingest.default_user_id())
      |> store()

    json(conn, %{stored: stored})
  end

  @doc """
  If a hook wants to backfill, it needs to know how many lines of the transcript
  have already been written.  This endpoint returns how many lines for a given
  scope have already been ingested so the hook script can pick up where it left
  off.
  """
  @spec lines_seen(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def lines_seen(conn, params) do
    count =
      params
      |> Ingest.scope(Ingest.default_user_id())
      |> Messages.lines_seen()

    json(conn, %{lines_seen: count})
  end

  defp store({:ok, messages, _drops}) do
    case Messages.put(messages) do
      {:ok, count} -> count
      {:error, _exception} -> 0
    end
  end

  defp store({:error, _reason}), do: 0

  # Claude Code renames the session to whatever comes back here, so the prompt's
  # first line is the cheapest thing that distinguishes one session from
  # another. A non-binary `prompt` is a client that is not Claude Code; it gets
  # the constant rather than an exception.
  defp session_title(prompt) when is_binary(prompt) do
    prompt
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim()
    |> String.slice(0, 60)
    |> case do
      "" -> "mem0 hook session"
      title -> title
    end
  end

  defp session_title(_prompt), do: "mem0 hook session"
end
