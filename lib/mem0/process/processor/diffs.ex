defmodule Mem0.Processor.Diffs do
  @moduledoc """
  Extracts code guidelines from stored diffs and files them as facts: what
  the developer changed, or asked to change, in code the agent wrote.
  """

  import Util

  alias Mem0.CodeExtractor
  alias Mem0.Embeddings
  alias Mem0.Reconciler
  alias Mem0.Store.Diff
  alias Mem0.Store.Diffs
  alias Mem0.Store.Fact
  alias Mem0.Store.Facts
  alias Mem0.Store.Scope
  alias Mem0.Store.Scopes

  require Logger

  # One extractor call reads at most this much diff text; a settle larger
  # than that is split into several batches.
  @max_batch_chars 700_000

  @doc """
  Processes every scope with diffs past its watermark.
  """
  @spec process_diffs() :: {[{[Fact.t()], [Diff.t()]}], [term()]}
  def process_diffs do
    Scopes.stale_diffs()
    |> partition_map(fn scope ->
      case process_scope(scope.id) do
        {:ok, facts, diffs} ->
          {:ok, {facts, diffs}}

        err ->
          err
      end
    end)
  end

  @doc """
  Given a scope, extracts guidelines from its diffs past the watermark, one
  batch at a time.

  Stops at the first batch that fails: the ones before it are done and the
  watermark sits on the last of them.

  Options:
   - `:max_batch_chars` (default #{@max_batch_chars}) caps the diff text one
     extractor call reads
  """
  @spec process_scope(integer(), keyword()) :: {:ok, [Fact.t()], [Diff.t()]} | {:error, term()}
  def process_scope(scope_id, opts \\ []) do
    max_batch_chars = Keyword.get(opts, :max_batch_chars, @max_batch_chars)

    case Scopes.get(scope_id) do
      nil -> {:error, :scope_does_not_exist}
      %Scope{} = scope -> process_new_diffs(scope, max_batch_chars)
    end
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # Runs the scope's diffs past the watermark in batches, oldest first.
  @spec process_new_diffs(Scope.t(), pos_integer()) ::
          {:ok, [Fact.t()], [Diff.t()]} | {:error, term()}
  defp process_new_diffs(scope, max_batch_chars) do
    scope.id
    |> Diffs.for_scope(from: scope.last_extracted_diff_id)
    |> batches(max_batch_chars)
    |> Enum.reduce_while({:ok, scope, [], []}, fn batch, {:ok, scope, facts, diffs} ->
      case process_batch(batch, scope) do
        {:ok, scope, new_facts} ->
          {:cont, {:ok, scope, facts ++ new_facts, diffs ++ batch}}

        err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, _scope, facts, diffs} ->
        {:ok, facts, diffs}

      err ->
        err
    end
  end

  # Extract from one batch, reconcile against the scope's guidelines, embed,
  # then move the watermark to the batch's last diff: the same steps a
  # message batch takes in `Mem0.Processor`.
  @spec process_batch([Diff.t()], Scope.t()) :: {:ok, Scope.t(), [Fact.t()]} | {:error, term()}
  defp process_batch(batch, scope) do
    with {:ok, guidelines} <- CodeExtractor.extract_guidelines(batch),
         :ok = log_extracted(batch, scope, guidelines),
         old_facts = Facts.facts_for(scope.id, kind: :guideline),
         facts = Reconciler.reconcile_facts(guidelines, old_facts, scope.id, :guideline),
         {:ok, facts} <- Embeddings.embed_facts(facts),
         {:ok, scope} <- Scopes.set_last_extracted_diff(scope, List.last(batch).id) do
      {:ok, scope, facts}
    end
  end

  # Splits diffs into batches whose diff text stays under `max_chars`. A
  # single diff larger than that is a batch on its own.
  @spec batches([Diff.t()], pos_integer()) :: [[Diff.t()]]
  defp batches(diffs, max_chars) do
    Enum.chunk_while(
      diffs,
      {[], 0},
      fn diff, {batch, size} ->
        chars = String.length(diff.diff)

        if batch != [] and size + chars > max_chars do
          {:cont, Enum.reverse(batch), {[diff], chars}}
        else
          {:cont, {[diff | batch], size + chars}}
        end
      end,
      fn
        {[], _size} -> {:cont, []}
        {batch, _size} -> {:cont, Enum.reverse(batch), []}
      end
    )
  end

  # Console feedback for debugging: every batch and what the LLM pulled out
  # of it, before reconciliation decides what to do with it. An empty
  # result is logged too, so a quiet extractor is visible.
  @spec log_extracted([Diff.t()], Scope.t(), [String.t()]) :: :ok
  defp log_extracted(batch, scope, guidelines) do
    extracted =
      case guidelines do
        [] -> "  (none)"
        _ -> Enum.map_join(guidelines, "\n", &("  - " <> &1))
      end

    sources =
      Enum.map_join(batch, "\n", fn diff ->
        "--- diff #{diff.id} #{diff.file} (#{diff.origin || "unknown"})\n" <>
          String.trim_trailing(diff.diff)
      end)

    Logger.error(
      "Extracted #{length(guidelines)} guideline(s) from #{length(batch)} diff(s) (session #{scope.session}):\n" <>
        extracted <> "\nfrom diffs:\n" <> sources
    )
  end
end
