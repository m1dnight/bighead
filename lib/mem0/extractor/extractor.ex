defmodule Mem0.Extractor do
  @moduledoc """
  Extracts facts from the database.
  """

  alias Mem0.Extractor.Prompt
  alias Mem0.Store.Facts
  alias Mem0.Store.Scopes

  @max_messages 50

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
    with scope when not is_nil(scope) <- Scopes.get(scope_id),
         messages = truncate_messages(messages, scope),
         {:ok, request} <- request(messages, summary),
         {:ok, response} <- Mem0.LLM.complete(request),
         {:ok, facts} <- decode_response(response),
         {:ok, facts} <- store_facts(facts, scope_id),
         :ok <- bump_scope_watermark(messages, scope) do
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

  defp truncate_messages(messages, scope) do
    case scope do
      %{last_extracted_message_id: nil} ->
        messages

      %{last_extracted_message_id: index} ->
        Enum.reject(messages, &(&1.id <= index))
    end
    |> Enum.sort_by(& &1.id, :asc)
    |> Enum.take(@max_messages)
    |> tap(&IO.inspect(&1, label: "messages"))
  end

  defp bump_scope_watermark(messages, scope) do
    latest_message_id = messages |> List.last() |> Map.get(:id)

    Scopes.set_last_extracted(scope, latest_message_id)
  end

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
  defp decode_response(%{content: json_str}) do
    IO.inspect(json_str)

    case Jason.decode(json_str) do
      {:ok, %{"facts" => facts}} ->
        {:ok, facts}

      _ ->
        {:error, :invalid_response_from_llm}
    end
  end
end
