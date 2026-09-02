defmodule Mem0.Recaller do
  @moduledoc """
  Recalls relevant facts for a given prompt.
  """

  alias Mem0.Embedder
  alias Mem0.Store.Fact
  alias Mem0.Store.Facts

  # How many facts a prompt may pull in, and how similar a fact must be to
  # qualify. 0.5 is a coarse floor for 768-wide sentence embeddings: unrelated
  # texts land well below it, paraphrases well above.
  @limit 30
  @min_similarity 0.5

  @doc """
  Returns the facts most relevant to `prompt`, most relevant first.

  Options:
   - `:limit` (default #{@limit}) caps how many facts come back
   - `:min_similarity` (default #{@min_similarity}) drops facts less similar
     than the floor. No relevant facts is `{:ok, []}`, not an error.
   - `:kind` keeps only facts of that kind (`:fact` or `:guideline`); every
     kind by default
  """
  @spec recall(String.t(), keyword()) :: {:ok, [Fact.t()]} | {:error, :failed_to_embed_prompt}
  def recall(prompt, opts \\ []) do
    limit = Keyword.get(opts, :limit, @limit)
    min_similarity = Keyword.get(opts, :min_similarity, @min_similarity)
    kind = Keyword.get(opts, :kind)

    case Embedder.embed([prompt]) do
      {:ok, [embedding]} ->
        facts =
          embedding
          |> Facts.most_similar(limit, kind: kind)
          |> Enum.filter(fn {similarity, _fact} -> similarity >= min_similarity end)
          |> Enum.map(fn {_similarity, fact} -> fact end)

        {:ok, facts}

      {:error, _reason} ->
        {:error, :failed_to_embed_prompt}
    end
  end
end
