defmodule Mem0.Extractor do
  @moduledoc """
  Extracts facts from the database.
  """

  alias Mem0.Extractor.Prompt
  alias Mem0.Store.Facts

  @response_schema %{
    "additionalProperties" => false,
    "properties" => %{"facts" => %{"items" => %{"type" => "string"}, "type" => "array"}},
    "required" => ["facts"],
    "type" => "object"
  }

  @doc """
  Extracts facts from a set of messags.
  """
  def extract_facts(messages, summary, scope_id) do
    request = request(messages)

    with {:ok, response} <- Mem0.LLM.complete(request),
         {:ok, facts} <- decode_response(response) do
      IO.inspect(facts)
      store_facts(facts, scope_id)
    end
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  defp store_facts(facts, scope_id) do
    facts
    |> Enum.reduce_while({[], []}, fn fact, {facts, errors} ->
      attrs = %{fact: fact, scope_id: scope_id}

      case Facts.create(attrs) do
        {:ok, fact} ->
          {:cont, {[fact | facts], errors}}

        {:error, err} ->
          {:halt, {facts, [{attrs, err} | errors]}}
      end
    end)
    |> case do
      {facts, []} ->
        {:ok, facts}

      {facts, errs} ->
        {:error, :partial, facts, errs}
    end
  end

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
    IO.inspect json_str
    case Jason.decode(json_str) do
      {:ok, %{"facts" => facts}} ->
        {:ok, facts}

      _ ->
        {:error, :invalid_response_from_llm}
    end
  end
end
