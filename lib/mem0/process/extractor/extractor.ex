defmodule Bighead.Extractor do
  @moduledoc """
  Extracts facts from the database.
  """

  alias Bighead.Extractor.Prompt
  alias Bighead.Store.Message

  @response_schema %{
    "additionalProperties" => false,
    "properties" => %{"facts" => %{"items" => %{"type" => "string"}, "type" => "array"}},
    "required" => ["facts"],
    "type" => "object"
  }

  @doc """
  Extracts facts from a set of messags.
  """
  @spec extract_facts([Message.t()], String.t() | nil) :: {:ok, [String.t()]} | {:error, term()}

  def extract_facts([], _) do
    {:ok, []}
  end

  def extract_facts(messages, summary) do
    with {:ok, request} <- request(messages, summary),
         {:ok, response} <- Bighead.LLM.complete(request),
         {:ok, facts} <- decode_response(response) do
      {:ok, facts}
    else
      # no messages to be extracted is not an error, well just call it ok with 0
      # facts.
      {:error, :no_messages_to_extract_from} ->
        {:ok, []}

      err ->
        err
    end
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # generates the request to complete via the LLM.
  @spec request([Message.t()], String.t() | nil) ::
          {:ok, Bighead.LLM.request()} | {:error, :no_messages_to_extract_from}
  def request([], _) do
    {:error, :no_messages_to_extract_from}
  end

  def request(messages, summary) do
    prompt = Prompt.render(messages: messages, summary: summary)

    {:ok,
     %{
       messages: [%{role: :user, content: prompt}],
       schema: @response_schema,
       system: Prompt.system_prompt()
     }}
  end

  # decodes the response from the LLM into a list of facts.
  @spec decode_response(Bighead.LLM.response()) ::
          {:ok, [String.t()]} | {:error, :invalid_response_from_llm}
  defp decode_response(%{content: json_str}) do
    case Jason.decode(json_str) do
      {:ok, %{"facts" => facts}} ->
        {:ok, facts}

      _ ->
        {:error, :invalid_response_from_llm}
    end
  end
end
