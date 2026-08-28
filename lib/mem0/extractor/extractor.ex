defmodule Mem0.Extractor do
  @moduledoc """
  Extracts facts from the database.
  """

  alias Mem0.Extractor.Prompt
  alias Mem0.Store.Fact
  alias Mem0.Store.Facts
  alias Mem0.Store.Message
  alias Mem0.Store.Scope
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
  @spec extract_facts([Message.t()], String.t() | nil, integer()) ::
          {:ok, [Fact.t()]}
          | {:error, term()}
          | {:error, :partial, [Fact.t()], [{map(), Ecto.Changeset.t()}]}
  def extract_facts(messages, summary, scope_id) do
    with scope when not is_nil(scope) <- Scopes.get(scope_id),
         messages = truncate_messages(messages, scope),
         {:ok, request} <- request(messages, summary),
         {:ok, response} <- Mem0.LLM.complete(request),
         {:ok, facts} <- decode_response(response)  do
      {:ok, facts}
    else
      # no messages to be extracted is not an error, well just call it ok with 0
      # facts.
      {:error, :no_messages_to_extract_from} ->
        {:ok, []}

      nil ->
        {:error, :scope_not_found}

      err ->
        err
    end
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  @spec truncate_messages([Message.t()], Scope.t()) :: [Message.t()]
  defp truncate_messages(messages, scope) do
    case scope do
      %{last_extracted_message_id: nil} ->
        messages

      %{last_extracted_message_id: index} ->
        Enum.reject(messages, &(&1.id <= index))
    end
    |> Enum.sort_by(& &1.id, :asc)
    |> Enum.take(@max_messages)
  end

  # @spec bump_scope_watermark([Message.t()], Scope.t()) ::
  #         {:ok, Scope.t()} | {:error, Ecto.Changeset.t()}
  # defp bump_scope_watermark(messages, scope) do
  #   latest_message_id = messages |> List.last() |> Map.get(:id)

  #   Scopes.set_last_extracted(scope, latest_message_id)
  # end

  # @spec store_facts([String.t()], integer()) ::
  #         {:ok, [Fact.t()]} | {:error, :partial, [Fact.t()], [{map(), Ecto.Changeset.t()}]}
  # defp store_facts(facts, scope_id) do
  #   facts
  #   |> Enum.reduce_while({[], []}, fn fact, {facts, errors} ->
  #     attrs = %{fact: fact, scope_id: scope_id}

  #     case Facts.create(attrs) do
  #       {:ok, fact} ->
  #         {:cont, {[fact | facts], errors}}

  #       {:error, err} ->
  #         {:halt, {facts, [{attrs, err} | errors]}}
  #     end
  #   end)
  #   |> case do
  #     {facts, []} ->
  #       {:ok, facts}

  #     {facts, errs} ->
  #       {:error, :partial, facts, errs}
  #   end
  # end

  # generates the request to complete via the LLM.
  @spec request([Message.t()], String.t() | nil) ::
          {:ok, Mem0.LLM.request()} | {:error, :no_messages_to_extract_from}
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
  @spec decode_response(Mem0.LLM.response()) ::
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
