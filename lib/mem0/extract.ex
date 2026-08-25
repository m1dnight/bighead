defmodule Mem0.Extract do
  @moduledoc """
  Extracts facts from messages, with one LLM call.
  """

  alias Mem0.Core.Extraction
  alias Mem0.Core.Message
  alias Mem0.LLM

  @doc """
  Extracts facts from `messages`.

  The scope of the messages is assumed to be the same for all messages, and is
  therefore taken from the first message in the list.

  `opts` reaches `Mem0.LLM.complete/2` untouched, so one call can raise
  `max_tokens` or change the model without touching configuration.

  One instant stamps both the extraction's `prompt_at` and every fact's
  `extracted_at`. They differ by the latency of the call, and nothing consumes
  that difference.
  """
  @spec facts([Message.t()], keyword()) :: {:ok, Extraction.t()} | {:error, term()}
  def facts(messages, opts \\ [])

  def facts([], _opts) do
    {:error, :no_messages}
  end

  def facts([%Message{scope: scope} | _rest] = messages, opts) do
    at = DateTime.utc_now()

    request = Extraction.request(messages)

    with {:ok, response} <- LLM.complete(request, opts) do
      IO.inspect response, label: "llm response"
      Extraction.decode(response.content, scope, at, Enum.map(messages, & &1.id))
    end
  end
end
