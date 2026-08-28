defmodule Mem0.Embeddings do
  @moduledoc """
  Embeds a fact using the embedder.
  """

  alias Mem0.Embedder
  alias Mem0.Store.Fact
  alias Mem0.Store.Facts

  @doc """
  Given a lsit of facts, computes their embedding if they were not present yet.
  """
  @spec embed_facts([Fact.t()]) :: [:ok | {:error, Embedder.reason()}]
  def embed_facts(facts) do
    facts
    |> Stream.reject(&(&1.embedding_768 != nil))
    |> Stream.chunk_every(5)
    |> Enum.map(&embed_batch/1)
  end

  @spec embed_batch([Fact.t()]) :: :ok | {:error, Embedder.reason()}
  defp embed_batch(facts) do
    contents = Enum.map(facts, & &1.fact)

    with {:ok, embeddings} <- Embedder.embed(contents) do
      facts
      |> Enum.zip(embeddings)
      |> Enum.each(fn {fact, embedding} ->
        {:ok, _fact} = Facts.update(fact, %{embedding_768: embedding})
      end)
    end
  end
end
