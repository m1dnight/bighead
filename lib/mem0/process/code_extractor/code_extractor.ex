defmodule Mem0.CodeExtractor do
  @moduledoc """
  Extracts durable code guidelines from a batch of diffs: what the developer
  changed, or asked to change, in code a coding agent wrote.
  """

  alias Mem0.CodeExtractor.Prompt
  alias Mem0.Store.Diff

  @response_schema %{
    "additionalProperties" => false,
    "properties" => %{"guidelines" => %{"items" => %{"type" => "string"}, "type" => "array"}},
    "required" => ["guidelines"],
    "type" => "object"
  }

  @doc """
  Extracts guidelines from a batch of diffs in one call. The batch is
  rendered grouped by file, oldest change first, so the model reads each
  file's history in order.
  """
  @spec extract_guidelines([Diff.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def extract_guidelines(diffs) do
    with {:ok, request} <- request(diffs),
         {:ok, response} <- Mem0.LLM.complete(request),
         {:ok, guidelines} <- decode_response(response) do
      {:ok, guidelines}
    else
      # blank diffs hold no guidelines, which is not an error — the same
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
  @spec request([Diff.t()]) :: {:ok, Mem0.LLM.request()} | {:error, :no_diff_to_extract_from}
  def request(diffs) do
    diffs =
      diffs
      |> Enum.reject(&(String.trim(&1.diff) == ""))
      |> Enum.sort_by(&{&1.file, &1.id})

    if diffs == [] do
      {:error, :no_diff_to_extract_from}
    else
      {:ok,
       %{
         messages: [%{role: :user, content: Prompt.render(diffs: diffs)}],
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
      {:ok, %{"guidelines" => guidelines}} when is_list(guidelines) ->
        {:ok, guidelines}

      _ ->
        {:error, :invalid_response_from_llm}
    end
  end
end
