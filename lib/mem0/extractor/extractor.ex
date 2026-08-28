defmodule Mem0.Extractor do
  @moduledoc """
  Extracts facts from the database.
  """

  alias Mem0.Extractor.Prompt

  @response_schema %{
    "additionalProperties" => false,
    "properties" => %{"facts" => %{"items" => %{"type" => "string"}, "type" => "array"}},
    "required" => ["facts"],
    "type" => "object"
  }

  @doc """
  Extracts facts from a set of messags.
  """
  def extract_facts(messages, summary, scope) do
    request = request(messages)

    with {:ok, response} <- Mem0.LLM.complete(request) do
      decode_response(response)
    end
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # generates the request to complete via the LLM.
  def request(messages) do
    prompt = Prompt.render(messages: messages)

    %{
      messages: [%{role: :user, content: prompt}],
      schema: @response_schema,
      system: Prompt.system_prompt()
    }
  end

  # decodes the response from the LLM into a list of facts.
  defp decode_response(%{content: json_str}) do
    case Jason.decode(json_str) do
      {:ok, %{"facts" => facts}} ->
        {:ok, facts}

      _ ->
        {:error, :invalid_response_from_llm}
    end
  end
end
