defmodule Mem0.Embeddings do
  @moduledoc """
  Embeds a fact using the embedder.
  """

  import Util

  alias Mem0.Embedder
  alias Mem0.Store.Fact
  alias Mem0.Store.Facts

  require Logger

  @doc """
  Given a list of facts, computes their embedding if they were not present yet.
  """
  @spec embed_facts([Fact.t()]) :: {:ok, [Fact.t()]} | {:error, :failed_to_embed_facts}
  def embed_facts(facts) do
    facts
    |> Stream.reject(&(&1.embedding_768 != nil))
    |> partition_map(fn fact ->
      with {:ok, [embedding]} <- Embedder.embed([fact.fact]),
           {:ok, fact} <- Facts.update(fact, %{embedding_768: embedding}) do
        {:ok, fact}
      else
        _ ->
          {:error, :failed_to_embed_fact}
      end
    end)
    |> case do
      {facts, []} ->
        {:ok, facts}

      {[], _failed} ->
        {:error, :failed_to_embed_facts}

      {facts, _failed} ->
        Logger.warning("Failed to embed some facts")
        {:ok, facts}
    end
  end
end
