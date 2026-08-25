defmodule Mem0.Summarize do
  @moduledoc """
  Creates a summary `S` of a list of messages.

  Summaries allow the LLM to extract more relevant facts for a conversation.
  """

  alias Mem0.Core.Message
  alias Mem0.Core.Summary
  alias Mem0.LLM

  @doc """
  Generates a summary for a given list of messages.
  """
  @spec regenerate([Message.t()], keyword()) :: {:ok, Summary.t()} | {:error, term()}
  def regenerate(messages, opts \\ [])

  def regenerate([], _opts) do
    {:error, :no_messages}
  end

  def regenerate([%Message{scope: scope} | _rest] = messages, opts) do
    generated_at = DateTime.utc_now()
    %Message{seq: through_seq} = Enum.max_by(messages, & &1.seq)

    # create a request for the LLM module to process.
    # This contains the messages, the system prompt and the schema.
    request = Summary.request(messages)

    with {:ok, response} <- LLM.complete(request, opts) do
      Summary.decode(response.content, scope, generated_at, through_seq)
    end
  end
end
