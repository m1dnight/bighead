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

  An optional `"kind"` of `"fact"` or `"guideline"` narrows the reply to
  that kind. A prompt no stored fact resembles gets an empty list, not an
  error.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"prompt" => prompt} = params) when is_binary(prompt) and prompt != "" do
    with {:ok, kind} <- kind(params["kind"]),
         {:ok, facts} <- Recaller.recall(prompt, kind: kind) do
      render(conn, :create, facts: facts)
    else
      {:error, :unknown_kind} ->
        conn
        |> put_status(422)
        |> render(:error, message: ~s(expected "kind" to be "fact" or "guideline"))

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

  # The optional "kind" field; absent means every kind. A fixed mapping, so
  # no client string ever becomes an atom.
  @spec kind(term()) :: {:ok, :fact | :guideline | nil} | {:error, :unknown_kind}
  defp kind(nil), do: {:ok, nil}
  defp kind("fact"), do: {:ok, :fact}
  defp kind("guideline"), do: {:ok, :guideline}
  defp kind(_other), do: {:error, :unknown_kind}
end
