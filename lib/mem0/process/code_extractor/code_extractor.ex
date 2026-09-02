defmodule Mem0.CodeExtractor do
  @moduledoc """
  Extracts durable code guidelines from a diff: the developer's edits to code
  a coding agent wrote.
  """

  alias Mem0.CodeExtractor.Prompt
  alias Mem0.Store.Diff

  require Logger
  @response_schema %{
    "additionalProperties" => false,
    "properties" => %{"guidelines" => %{"items" => %{"type" => "string"}, "type" => "array"}},
    "required" => ["guidelines"],
    "type" => "object"
  }

  @doc """
  Extracts guidelines from one diff.
  """
  @spec extract_guidelines(Diff.t()) :: {:ok, [String.t()]} | {:error, term()}
  def extract_guidelines(diff) do
    with {:ok, request} <- request(diff),
         {:ok, response} <- Mem0.LLM.complete(request),
         {:ok, guidelines} <- decode_response(response) do

      Logger.warning """
      Diff: #{inspect diff}
      Guidelines: #{inspect guidelines}
      """
      {:ok, guidelines}
    else
      # a blank diff holds no guidelines, which is not an error — the same
      # posture as the extractor's empty message batch.
      {:error, :no_diff_to_extract_from} ->
        {:ok, []}

      err ->
        err
    end
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # generates the request to complete via the LLM.
  @spec request(Diff.t()) :: {:ok, Mem0.LLM.request()} | {:error, :no_diff_to_extract_from}
  def request(%Diff{} = diff) do
    if String.trim(diff.diff) == "" do
      {:error, :no_diff_to_extract_from}
    else
      prompt = Prompt.render(file: diff.file, diff: diff.diff)

      {:ok,
       %{
         messages: [%{role: :user, content: prompt}],
         schema: @response_schema,
         system: Prompt.system_prompt()
       }}
    end
  end

  # decodes the response from the LLM into a list of guidelines.
  @spec decode_response(Mem0.LLM.response()) ::
          {:ok, [String.t()]} | {:error, :invalid_response_from_llm}
  defp decode_response(%{content: json_str}) do
    case Jason.decode(json_str) do
      {:ok, %{"guidelines" => guidelines}} ->
        {:ok, guidelines}

      _ ->
        {:error, :invalid_response_from_llm}
    end
  end
end
