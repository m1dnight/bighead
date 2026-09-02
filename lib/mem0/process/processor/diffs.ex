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
  @max_batch_chars 800_000

  # How many of the agent's earlier diffs on a file come along as context.
  @max_context_per_file 10

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
      Logger.warning "Processing batch of size #{Enum.count(diffs)}"
      case process_batch(batch, scope) do
        {:ok, scope, new_facts} ->
          Logger.warning "Facts from diffs: #{inspect new_facts}"
          {:cont, {:ok, scope, facts ++ new_facts, diffs ++ batch}}

        err ->
          Logger.error "Failed to process batch"
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
    with {:ok, guidelines} <- CodeExtractor.extract_guidelines(with_context(batch, scope)),
         :ok = log_extracted(batch, guidelines),
         old_facts = Facts.facts_for(scope.id, kind: :guideline),
         facts = Reconciler.reconcile_facts(guidelines, old_facts, scope.id, :guideline),
         {:ok, facts} <- Embeddings.embed_facts(facts),
         {:ok, scope} <- Scopes.set_last_extracted_diff(scope, List.last(batch).id) do
      {:ok, scope, facts}
    end
  end

  # The batch plus, for each file in it, the agent's diffs on that file since
  # the developer last changed it. Those were extracted already; they come
  # along as the before-picture of a developer change in the batch, which
  # usually lands in a later batch than the agent's work it reacts to.
  @spec with_context([Diff.t()], Scope.t()) :: [Diff.t()]
  defp with_context(batch, scope) do
    first_id = List.first(batch).id

    context =
      batch
      |> Enum.map(& &1.file)
      |> Enum.uniq()
      |> Enum.flat_map(fn file ->
        scope.id
        |> Diffs.before(file, first_id, @max_context_per_file)
        |> Enum.take_while(&(&1.origin in [:agent, :requested]))
      end)

    context ++ batch
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

        if not Enum.empty?(batch) and size + chars > max_chars do
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

  # Console feedback for debugging: one line per diff, then the guidelines
  # one per line, so a scan of the log shows what came out of what.
  @spec log_extracted([Diff.t()], [String.t()]) :: :ok
  defp log_extracted(batch, guidelines) do
    diffs = Enum.map_join(batch, "\n", &("diff: " <> preview(&1.diff)))

    facts =
      case guidelines do
        [] -> " none"
        _ -> "\n" <> Enum.map_join(guidelines, "\n", &("  " <> &1))
      end

    Logger.error(diffs <> ": facts:" <> facts)
  end

  # The first 20 characters of a diff's changed lines, on one line. The
  # header before the first hunk names blobs, not content, so it is skipped.
  @spec preview(String.t()) :: String.t()
  defp preview(diff) do
    diff
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "@@")))
    |> Enum.drop(1)
    |> Enum.join(" ")
    |> String.slice(0, 20)
  end
end
