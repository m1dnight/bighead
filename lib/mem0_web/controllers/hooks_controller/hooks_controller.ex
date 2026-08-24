defmodule Mem0Web.HooksController do
  @moduledoc """
  Controller for the Claude Code hooks mem0 listens on.

  Two events, with disjoint jobs and different response contracts:

    * `UserPromptSubmit` — recall. The prompt is augmented with facts fetched
      from the database. We append the facts at the bottom of the prompt to make
      sure we do not invalidate the cache.

    * `Stop` — ingest. Fires when the agent has finished responding to the user.
      This means we have a clean cutoff of the transcript and we can extract
      facts from this.

  Both answer 200 unconditionally, including on a parse that produced nothing.
  `UserPromptSubmit` blocks the session that fired it, so that route must never
  be why a turn stalls, and `Stop`'s body is inert by construction.
  """
  use Mem0Web, :controller

  alias Mem0.Ingest
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
  `Stop`. Ingests the posted transcript tail and answers.
  """
  @spec stop(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def stop(conn, params) do
    _result = Ingest.receive(params, Ingest.default_user_id())

    json(conn, HookResponse.stop())
  end

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
