defmodule Mem0.ReconcileTest do
  @moduledoc """
  Algorithm 1 against the real store, with scripted verdicts. `reconcile/2`
  is driven with fixture extractions — the four arms, the sequential
  property, the skip posture — and `pulse/2` with stored messages, because
  the cursor rules are the pulse's own.

  `async: false` for `Mem0.SummarizeRefreshTest`'s reason: `pulse_async/2`
  runs on a task under the application's `Task.Supervisor`, and only the
  sandbox's shared mode lets that process use this test's connection.
  """

  use Mem0.DataCase, async: false
  use Mem0.CoreFixtures

  alias Mem0.Embedder
  alias Mem0.ExtractionState
  alias Mem0.LLM
  alias Mem0.Memories
  alias Mem0.Memories.Row
  alias Mem0.Messages
  alias Mem0.Reconcile

  setup do
    LLM.Stub.start!()
    Embedder.Stub.start!()
    :ok
  end

  describe "reconcile/2 — the four arms" do
    test "ADD lands a memory the store can read back, findable by the fact's vector" do
      LLM.Stub.set(verdict(%{"event" => "ADD", "reason" => "Nothing covers this."}))
      fact = fact(content: "User uses Elixir")

      assert {:ok, [decision]} = Reconcile.reconcile(extraction(facts: [fact]), at: at(10))

      assert decision.operation == {:add, fact}
      assert decision.decided_at == at(10)
      assert decision.considered_ids == []

      assert [%Memory{content: "User uses Elixir"} = memory] = Memories.active(query())
      assert memory.created_at == at(10)

      {:ok, [vector]} = Embedder.embed([fact.content])
      assert [{score, found}] = Memories.search(query(), vector, 1)
      assert found.id == memory.id
      assert score > 0.999
    end

    test "UPDATE keeps the id, replaces the content, and moves the vector" do
      seeded = seed("User drinks coffee")
      LLM.Stub.set(verdict(%{"event" => "UPDATE", "id" => 1, "reason" => "More detail."}))
      fact = fact(content: "User drinks oat milk lattes every morning")

      assert {:ok, [decision]} = Reconcile.reconcile(extraction(facts: [fact]), at: at(10))

      assert decision.operation == {:update, seeded.id, fact}
      assert decision.considered_ids == [seeded.id]

      assert [updated] = Memories.active(query())
      assert updated.id == seeded.id
      assert updated.content == fact.content
      assert updated.created_at == seeded.created_at
      assert updated.updated_at == at(10)

      {:ok, [vector]} = Embedder.embed([fact.content])
      assert [{score, found}] = Memories.search(query(), vector, 1)
      assert found.id == seeded.id
      assert score > 0.999
    end

    test "DELETE supersedes: gone from active, row still present" do
      seeded = seed("User works at Initech")
      LLM.Stub.set(verdict(%{"event" => "DELETE", "id" => 1, "reason" => "Contradicted."}))
      fact = fact(content: "User no longer works at Initech")

      assert {:ok, [decision]} = Reconcile.reconcile(extraction(facts: [fact]), at: at(10))

      assert decision.operation == {:delete, seeded.id}
      assert Memories.active(query()) == []
      assert %Row{superseded_at: superseded_at} = Repo.get!(Row, seeded.id)
      assert superseded_at == at(10)
    end

    test "NOOP leaves the store untouched" do
      seed("User uses Elixir")
      untouched = Memories.active(query())
      LLM.Stub.set(verdict(%{"event" => "NOOP", "reason" => "Already known."}))

      assert {:ok, [decision]} =
               Reconcile.reconcile(extraction(facts: [fact(content: "User uses Elixir")]),
                 at: at(10)
               )

      assert decision.operation == :noop
      assert Memories.active(query()) == untouched
    end

    test "an UPDATE that adds nothing degrades to :noop against the real store" do
      seeded = seed("User drinks strong black coffee")
      LLM.Stub.set(verdict(%{"event" => "UPDATE", "id" => 1, "reason" => "Rephrases it."}))

      assert {:ok, [decision]} =
               Reconcile.reconcile(extraction(facts: [fact(content: "User likes coffee")]),
                 at: at(10)
               )

      assert decision.operation == :noop
      assert [untouched] = Memories.active(query())
      assert untouched.content == seeded.content
      assert untouched.updated_at == seeded.updated_at
    end
  end

  describe "reconcile/2 — the sequential property and the skip posture" do
    test "fact 2 sees the memory fact 1 just added" do
      fact_one = fact(content: "User plays guitar")
      fact_two = fact(content: "User plays acoustic guitar in a band")

      LLM.Stub.set(fn request, _opts ->
        [%{content: content}] = request.messages

        if content =~ "# Candidate fact\nUser plays guitar\n" do
          verdict(%{"event" => "ADD", "reason" => "New."})
        else
          verdict(%{"event" => "UPDATE", "id" => 1, "reason" => "More detail."})
        end
      end)

      assert {:ok, [first, second]} =
               Reconcile.reconcile(extraction(facts: [fact_one, fact_two]), at: at(10))

      # One memory: added by fact 1, then updated in place by fact 2 — the
      # immediately-usable property. A concurrent reconcile would have added
      # two.
      assert [only] = Memories.active(query())
      assert only.content == fact_two.content
      assert first.operation == {:add, fact_one}
      assert second.operation == {:update, only.id, fact_two}
      assert second.considered_ids == [only.id]

      # Fact 2's request listed fact 1's memory as ordinal 1.
      assert [_fact_one_request, fact_two_request] = LLM.Stub.calls()
      assert [%{content: content}] = fact_two_request.messages
      assert content =~ "1. User plays guitar"
    end

    test "a fact whose LLM call fails is skipped; the rest still reconcile" do
      fact_one = fact(content: "User plays guitar")
      fact_two = fact(content: "User lives in Ghent")

      LLM.Stub.set(fn request, _opts ->
        [%{content: content}] = request.messages

        if content =~ "User plays guitar" do
          {:error, {:http_error, 500, %{}}}
        else
          verdict(%{"event" => "ADD", "reason" => "New."})
        end
      end)

      assert {:ok, [decision]} =
               Reconcile.reconcile(extraction(facts: [fact_one, fact_two]), at: at(10))

      assert decision.operation == {:add, fact_two}
      assert [%Memory{content: "User lives in Ghent"}] = Memories.active(query())
    end

    test "no candidate memory id appears in any request sent to the model" do
      seed("User drinks coffee")
      seed("User likes tea")
      ids = Enum.map(Memories.active(query()), & &1.id)
      LLM.Stub.set(verdict(%{"event" => "NOOP", "reason" => "Known."}))

      assert {:ok, _decisions} = Reconcile.reconcile(extraction(facts: [fact()]), at: at(10))
      assert [_request | _rest] = calls = LLM.Stub.calls()

      for request <- calls, %{content: content} <- request.messages, id <- ids do
        refute content =~ id
      end
    end
  end

  describe "pulse/2" do
    test "a pulse with nothing new spends no call and leaves no cursor" do
      assert Reconcile.pulse(scope()) == :nothing_new
      assert LLM.Stub.calls() == []
      assert ExtractionState.through_seq(scope()) == nil
    end

    test "a pulse extracts past the cursor, reconciles, and advances it" do
      scope = scope()
      store(scope, 1..2)
      LLM.Stub.set(scripted(["User uses Elixir"], %{"event" => "ADD", "reason" => "New."}))

      assert {:ok, [decision]} = Reconcile.pulse(scope)

      assert {:add, %Fact{content: "User uses Elixir"}} = decision.operation
      assert [%Memory{content: "User uses Elixir"}] = Memories.active(query())
      assert ExtractionState.through_seq(scope) == 2

      # The next pulse starts where this one stopped.
      assert Reconcile.pulse(scope) == :nothing_new
    end

    test "an extraction with zero facts still advances the cursor" do
      scope = scope()
      store(scope, 1..2)
      LLM.Stub.set(scripted([], %{}))

      assert {:ok, []} = Reconcile.pulse(scope)

      # The messages were considered — this case is why the cursor is its own
      # row rather than derived from memory provenance.
      assert ExtractionState.through_seq(scope) == 2
    end

    test "a pulse that fails mid-extraction leaves the cursor; the next one retries the slice" do
      scope = scope()
      store(scope, 1..2)
      LLM.Stub.set({:error, {:http_error, 429, %{}}})

      assert Reconcile.pulse(scope) == {:error, {:http_error, 429, %{}}}
      assert ExtractionState.through_seq(scope) == nil
      assert Memories.active(query()) == []

      LLM.Stub.set(scripted(["User uses Elixir"], %{"event" => "ADD", "reason" => "New."}))

      assert {:ok, [_decision]} = Reconcile.pulse(scope)
      assert [%Memory{content: "User uses Elixir"}] = Memories.active(query())
      assert ExtractionState.through_seq(scope) == 2
    end

    test "a skipped fact does not hold the cursor back, and reports without content" do
      attach_skip_telemetry()
      scope = scope()
      store(scope, 1..2)

      LLM.Stub.set(fn request, _opts ->
        [%{content: content}] = request.messages

        cond do
          request.system == Extraction.system_prompt() ->
            {:ok, LLM.Stub.response(~s({"facts": ["User plays guitar", "User lives in Ghent"]}))}

          content =~ "User plays guitar" ->
            {:error, {:http_error, 500, %{}}}

          true ->
            verdict(%{"event" => "ADD", "reason" => "New."})
        end
      end)

      assert {:ok, [decision]} = Reconcile.pulse(scope)

      assert {:add, %Fact{content: "User lives in Ghent"}} = decision.operation
      assert ExtractionState.through_seq(scope) == 2

      # The coarse tag rides on the event; the full reason term may carry
      # model output and stays off it.
      assert_receive {:skip_event, metadata}
      assert metadata.reason == :http_error
      assert metadata.user_id == scope.user_id
      assert map_size(metadata) == 4
    end
  end

  describe "pulse_async/2" do
    test "notifies the caller instead of making it sleep" do
      scope = scope()
      store(scope, 1..2)
      LLM.Stub.set(scripted(["User uses Elixir"], %{"event" => "ADD", "reason" => "New."}))

      assert Reconcile.pulse_async(scope, notify_pid: self()) == :ok

      assert_receive {:pulsed, ^scope, {:ok, [_decision]}}, 1_000
      assert [%Memory{content: "User uses Elixir"}] = Memories.active(query())
    end

    test "emits outcome telemetry carrying identifiers and counts, never text" do
      attach_pulse_telemetry()
      scope = scope()
      store(scope, 1..2)
      LLM.Stub.set(scripted(["User uses Elixir"], %{"event" => "ADD", "reason" => "New."}))

      Reconcile.pulse_async(scope)

      assert_receive {:pulse_event, measurements, metadata}, 1_000
      assert is_integer(measurements.duration)
      assert metadata.outcome == :reconciled
      assert metadata.operations == %{add: 1}
      assert metadata.user_id == scope.user_id
      assert metadata.app_id == scope.app_id
      assert metadata.run_id == scope.run_id
      # Identifiers, the outcome and the verb counts, nothing else: no fact
      # content, memory content or model reasoning may ride on an event the
      # redaction policy cannot filter.
      assert map_size(metadata) == 5

      Reconcile.pulse_async(scope)

      assert_receive {:pulse_event, _measurements, %{outcome: :nothing_new}}, 1_000
    end
  end

  # Reconciliation retrieves user-broad, so the read-back does too.
  defp query, do: ScopeQuery.new(user_id: "christophe")

  defp verdict(map), do: {:ok, LLM.Stub.response(Jason.encode!(map))}

  # One reply for the pulse's two kinds of question: the extraction request
  # gets `facts`, every update request gets `verdict_map`.
  defp scripted(facts, verdict_map) do
    fn request, _opts ->
      if request.system == Extraction.system_prompt() do
        {:ok, LLM.Stub.response(Jason.encode!(%{"facts" => facts}))}
      else
        verdict(verdict_map)
      end
    end
  end

  defp seed(content) do
    {:ok, [vector]} = Embedder.embed([content])
    {:ok, memory} = Memories.add(fact(content: content), vector, at(0))
    memory
  end

  defp store(scope, seqs) do
    {:ok, _count} =
      Messages.put(
        for seq <- seqs,
            do: message(id: "msg-#{seq}", scope: scope, content: "message #{seq}", seq: seq)
      )
  end

  @doc false
  def send_pulse_event(_event, measurements, metadata, pid),
    do: send(pid, {:pulse_event, measurements, metadata})

  @doc false
  def send_skip_event(_event, _measurements, metadata, pid),
    do: send(pid, {:skip_event, metadata})

  # External captures rather than local ones, for `Mem0.MessagesTest`'s
  # reason: `:telemetry` warns about local-function handlers.
  defp attach_pulse_telemetry do
    handler_id = {__MODULE__, :pulse, self()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:mem0, :reconcile, :pulse],
        &__MODULE__.send_pulse_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp attach_skip_telemetry do
    handler_id = {__MODULE__, :skip, self()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:mem0, :reconcile, :skip],
        &__MODULE__.send_skip_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
