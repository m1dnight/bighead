defmodule Mem0.Processor.Diffs do
  @moduledoc """
  Extracts code guidelines from stored diffs and files them as facts. Extracts
  code guidelines from diffs between llm-generated code and user edits made
  afterwards.
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
  Given a scope, extracts guidelines from its diffs past the watermark.

  Stops at the first diff that fails: the ones before it are done and the
  watermark sits on the last of them.
  """
  @spec process_scope(integer()) :: {:ok, [Fact.t()], [Diff.t()]} | {:error, term()}
  def process_scope(scope_id) do
    case Scopes.get(scope_id) do
      nil -> {:error, :scope_does_not_exist}
      %Scope{} = scope -> process_new_diffs(scope)
    end
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # Runs the scope's diffs past the watermark in order, oldest first.
  @spec process_new_diffs(Scope.t()) :: {:ok, [Fact.t()], [Diff.t()]} | {:error, term()}
  defp process_new_diffs(scope) do
    scope.id
    |> Diffs.for_scope(from: scope.last_extracted_diff_id)
    |> Enum.reduce_while({:ok, scope, [], []}, fn diff, {:ok, scope, facts, diffs} ->
      case process_diff(diff, scope) do
        {:ok, scope, new_facts} ->
          {:cont, {:ok, scope, facts ++ new_facts, [diff | diffs]}}

        err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, _scope, facts, diffs} ->
        {:ok, facts, Enum.reverse(diffs)}

      err ->
        err
    end
  end

  # Extract, reconcile against the scope's guidelines, embed, then move the
  # watermark: the same steps a message batch takes in `Mem0.Processor`.
  @spec process_diff(Diff.t(), Scope.t()) :: {:ok, Scope.t(), [Fact.t()]} | {:error, term()}
  defp process_diff(diff, scope) do
    with {:ok, guidelines} <- CodeExtractor.extract_guidelines(diff),
         :ok = log_extracted(diff, scope, guidelines),
         old_facts = Facts.facts_for(scope.id, kind: :guideline),
         facts = Reconciler.reconcile_facts(guidelines, old_facts, scope.id, :guideline),
         {:ok, facts} <- Embeddings.embed_facts(facts),
         {:ok, scope} <- Scopes.set_last_extracted_diff(scope, diff.id) do
      {:ok, scope, facts}
    end
  end

  # Console feedback for debugging: every diff and what the LLM pulled out
  # of it, before reconciliation decides what to do with it. An empty
  # result is logged too, so a quiet extractor is visible.
  @spec log_extracted(Diff.t(), Scope.t(), [String.t()]) :: :ok
  defp log_extracted(diff, scope, guidelines) do
    extracted =
      case guidelines do
        [] -> "  (none)"
        _ -> Enum.map_join(guidelines, "\n", &("  - " <> &1))
      end

    Logger.error(
      "Extracted #{length(guidelines)} guideline(s) from diff #{diff.id} of #{diff.file} (session #{scope.session}):\n" <>
        extracted <> "\nfrom diff:\n" <> String.trim_trailing(diff.diff)
    )
  end
end
