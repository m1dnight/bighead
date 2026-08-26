defmodule Mem0.Reconcile do
  @moduledoc """
  The boundary that performs Algorithm 1: a `Stop` pulse turns the run's new
  exchange into memories.

  `pulse/2` is read-cursor → extract → reconcile → advance-cursor, in that
  order, and the order is the crash-safety argument: the cursor advances only
  after reconciliation ran to completion. A pulse that crashes mid-cascade
  advances nothing, so the next `Stop` re-extracts the same slice —
  at-least-once, with the cascade as the dedup layer: a fact re-presented
  against the memory it already produced comes back NOOP (or UPDATE,
  harmlessly). Two pulses racing the same slice is the same story with the
  same absorber, plus `GREATEST` in `Mem0.ExtractionState.advance/3` keeping
  the cursor monotonic. Tolerated, not prevented.

  The core decides *what*, wrapped in a `Mem0.Core.Decision`; this module
  performs it. Nothing here puts a rule in the boundary that the core could
  hold.
  """

  alias Mem0.Core.Decision
  alias Mem0.Core.Extraction
  alias Mem0.Core.Fact
  alias Mem0.Core.Memory
  alias Mem0.Core.MemoryOperation
  alias Mem0.Core.Scope
  alias Mem0.Core.ScopeQuery
  alias Mem0.Embedder
  alias Mem0.Extract
  alias Mem0.ExtractionState
  alias Mem0.LLM
  alias Mem0.Memories
  alias Mem0.Reconcile.TaskSupervisor

  @task_supervisor TaskSupervisor

  # The paper's `s`: how many retrieved memories the cascade sees per fact.
  # Policy lives here — the store takes it as an argument so this module can
  # own it.
  @max_memories 10

  @doc """
  One update pulse for `scope`: extract facts past the stored cursor, drive
  each through the cascade, advance the cursor.

  One instant, read once here, stamps the whole pulse — every `decided_at`,
  `created_at` and `superseded_at` it produces, and the cursor's `pulsed_at`.

  A pulse with nothing new touches nothing: `Mem0.Extract.facts_since/3`
  refuses before any LLM call and the cursor stays. A pulse whose extraction
  yields *zero facts* advances the cursor — the messages were considered,
  which is why the cursor is not derived from memory provenance. A pulse
  whose extraction fails advances nothing, so the next pulse retries the
  slice.
  """
  @spec pulse(Scope.t(), keyword()) :: {:ok, [Decision.t()]} | :nothing_new | {:error, term()}
  def pulse(%Scope{} = scope, opts \\ []) do
    at = DateTime.utc_now()

    with {:ok, extraction} <- extract(scope, opts),
         {:ok, decisions} <- reconcile(extraction, Keyword.put(opts, :at, at)),
         :ok <- ExtractionState.advance(scope, extraction.through_seq, at) do
      {:ok, decisions}
    end
  end

  @doc """
  `pulse/2` on a supervised task, so the caller answers immediately.

  Always returns `:ok`; the outcome reports through telemetry, and through a
  `{:pulsed, scope, result}` message when `opts` carries a `:notify_pid`.
  """
  @spec pulse_async(Scope.t(), keyword()) :: :ok
  def pulse_async(%Scope{} = scope, opts \\ []) do
    {:ok, _pid} =
      Task.Supervisor.start_child(@task_supervisor, fn ->
        measured_pulse(scope, opts)
      end)

    :ok
  end

  @doc """
  Drives one extraction's facts through the cascade, sequentially.

  Per fact: embed the content, retrieve the top-#{@max_memories} similar
  memories, ask, decode, perform. Sequential rather than concurrent on
  purpose: facts from one exchange are often *about the same thing*, and fact
  2 must see the memory fact 1 just added or the cascade dedups nothing — the
  paper's incremental design says the same.

  A fact that fails does not kill the pulse: an LLM error, a malformed
  verdict, a store error on one fact is telemetered and skipped, and the
  remaining facts still reconcile. Memory is best-effort by nature, and one
  bad verdict costing the whole exchange would invert that posture.

  Returns the decisions in fact order, skipped facts omitted. They are not
  persisted — a decisions table needs a consumer.
  """
  @spec reconcile(Extraction.t(), keyword()) :: {:ok, [Decision.t()]}
  def reconcile(%Extraction{} = extraction, opts \\ []) do
    {at, opts} = Keyword.pop_lazy(opts, :at, &DateTime.utc_now/0)

    decisions =
      extraction.facts
      |> Enum.map(&reconcile_fact(&1, at, opts))
      |> Enum.reject(&is_nil/1)

    {:ok, decisions}
  end

  defp extract(scope, opts) do
    case Extract.facts_since(scope, ExtractionState.through_seq(scope), opts) do
      {:ok, extraction} -> {:ok, extraction}
      {:error, :nothing_new} -> :nothing_new
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_fact(%Fact{} = fact, at, opts) do
    with {:ok, [vector]} <- Embedder.embed([fact.content]),
         candidates = candidates(fact, vector),
         {:ok, decision} <- decide(fact, candidates, at, opts),
         :ok <- perform(decision.operation, candidates, vector, at) do
      decision
    else
      {:error, reason} ->
        skipped(fact.scope, reason)
        nil
    end
  end

  # Retrieval is user-broad on purpose: reconciliation is dedup, and a fact
  # stated in this run that contradicts a memory born in another app is
  # exactly the contradiction the cascade exists to catch. Narrowing to the
  # app or run would partition the user's memory into stores that cannot
  # correct each other. (Whether *recall* should read this broadly is a
  # different question and stays open.)
  defp candidates(%Fact{} = fact, vector) do
    [user_id: fact.scope.user_id]
    |> ScopeQuery.new()
    |> Memories.search(vector, @max_memories)
    |> Enum.map(fn {_score, memory} -> memory end)
  end

  defp decide(fact, candidates, at, opts) do
    with {:ok, response} <- LLM.complete(MemoryOperation.request(fact, candidates), opts) do
      MemoryOperation.decode(response.content, fact, candidates, at)
    end
  end

  # Performing is a translation, verb for verb. ADD reuses the vector the
  # fact was searched with — embed once. UPDATE's new content *is* the fact's
  # content, so the same vector is the fresh vector; no second embedding
  # exists to forget. DELETE leaves `by:` unset — the cascade knows what
  # contradicted, not which memory replaces the dead one.
  defp perform({:add, fact}, _candidates, vector, at) do
    with {:ok, _memory} <- Memories.add(fact, vector, at), do: :ok
  end

  defp perform({:update, id, fact}, candidates, vector, at) do
    # The id came out of `parse/4`'s ordinal lookup over this same list, so
    # the candidate is always in hand.
    candidates
    |> Enum.find(&(&1.id == id))
    |> Memory.apply_update(fact, at)
    |> Memories.update(vector)
  end

  defp perform({:delete, id}, _candidates, _vector, at) do
    Memories.supersede(id, at)
  end

  defp perform(:noop, _candidates, _vector, _at), do: :ok

  defp measured_pulse(scope, opts) do
    {notify_pid, opts} = Keyword.pop(opts, :notify_pid)
    {duration, result} = :timer.tc(fn -> pulse(scope, opts) end)

    :telemetry.execute(
      [:mem0, :reconcile, :pulse],
      %{duration: duration},
      %{
        outcome: outcome(result),
        operations: operations(result),
        user_id: scope.user_id,
        app_id: scope.app_id,
        run_id: scope.run_id
      }
    )

    if notify_pid, do: send(notify_pid, {:pulsed, scope, result})
  end

  # Identifiers and a coarse reason, never content — the redaction policy.
  # The full reason term may carry model output, so only its leading tag
  # rides on the event.
  defp skipped(scope, reason) do
    :telemetry.execute(
      [:mem0, :reconcile, :skip],
      %{},
      %{
        reason: tag(reason),
        user_id: scope.user_id,
        app_id: scope.app_id,
        run_id: scope.run_id
      }
    )
  end

  defp tag(reason) when is_atom(reason), do: reason
  defp tag(%module{}), do: module
  defp tag(reason) when is_tuple(reason) and is_atom(elem(reason, 0)), do: elem(reason, 0)
  defp tag(_reason), do: :unknown

  defp outcome({:ok, _decisions}), do: :reconciled
  defp outcome(:nothing_new), do: :nothing_new
  defp outcome({:error, _reason}), do: :error

  # Operation tags and counts, never content: how many of each verb this
  # pulse performed.
  defp operations({:ok, decisions}), do: Enum.frequencies_by(decisions, &verb(&1.operation))
  defp operations(_result), do: %{}

  defp verb({:add, _fact}), do: :add
  defp verb({:update, _id, _fact}), do: :update
  defp verb({:delete, _id}), do: :delete
  defp verb(:noop), do: :noop
end
