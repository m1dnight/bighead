defmodule Bighead.CodeExtractor do
  @moduledoc """
  Extracts durable code guidelines from a batch of diffs: what the developer
  changed, or asked to change, in code a coding agent wrote.
  """

  alias Bighead.CodeExtractor.Prompt
  alias Bighead.Store.Diff

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
         {:ok, response} <- Bighead.LLM.complete(request),
         {:ok, guidelines} <- decode_response(response) do
      {:ok, guidelines}
    else
      # blank diffs, or only the agent's own, hold no guidelines, which is not
      # an error — the same posture as the extractor's empty message batch.
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
  @spec request([Diff.t()]) :: {:ok, Bighead.LLM.request()} | {:error, :no_diff_to_extract_from}
  def request(diffs) do
    diffs =
      diffs
      |> Enum.reject(&(String.trim(&1.diff) == ""))
      |> Enum.sort_by(&{&1.file, &1.id})
      |> with_a_developer_change()

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

  # Keeps the files the developer changed something in. The agent's own diffs
  # are context for reading those; a file holding nothing else has no
  # guideline in it and only costs tokens.
  @spec with_a_developer_change([Diff.t()]) :: [Diff.t()]
  defp with_a_developer_change(diffs) do
    files = diffs |> Enum.reject(&(&1.origin == :agent)) |> MapSet.new(& &1.file)

    Enum.filter(diffs, &MapSet.member?(files, &1.file))
  end

  # decodes the response from the LLM into a list of guidelines.
  @spec decode_response(Bighead.LLM.response()) ::
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
