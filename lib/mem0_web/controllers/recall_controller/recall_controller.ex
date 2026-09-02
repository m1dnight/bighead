defmodule Mem0Web.RecallController do
  @moduledoc """
  Returns the stored facts most relevant to a prompt.

  The read side of `/v1/transcripts`: the hook script posts the user's
  prompt here on `UserPromptSubmit` and injects the reply into the session
  as context. Same posture as the other endpoints — the submitter waits for
  the reply, so it answers honestly: 422 for a payload that is not the
  expected shape, 502 when the embedder upstream is down.
  """

  use Mem0Web, :controller

  alias Mem0.Recaller

  defdelegate open_api_operation(action), to: Mem0Web.RecallApiSpec

  @doc """
  Recalls the facts relevant to one prompt:

      curl -X POST -H 'content-type: application/json' \\
        -d '{"prompt": "what am I working on?"}' \\
        http://localhost:4000/v1/recall

  A prompt no stored fact resembles gets an empty list, not an error.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"prompt" => prompt}) when is_binary(prompt) and prompt != "" do
    case Recaller.recall(prompt) do
      {:ok, facts} ->
        render(conn, :create, facts: facts)

      {:error, :failed_to_embed_prompt} ->
        conn
        |> put_status(502)
        |> render(:error, message: "could not embed the prompt")
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(422)
    |> render(:error, message: ~s(expected {"prompt": <non-empty text>}))
  end
end
