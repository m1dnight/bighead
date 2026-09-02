defmodule Mem0.Processor.DiffsTest do
  @moduledoc """
  The extract-then-embed pass over one scope's diffs, with both ports
  stubbed: a batch of diffs goes to the extractor in one call, guidelines
  land in the store as embedded facts, and the diff watermark moves so the
  next pass reads nothing twice.
  """
  use Mem0.DataCase, async: true

  alias Mem0.Embedder
  alias Mem0.LLM
  alias Mem0.Processor
  alias Mem0.Store.Diffs
  alias Mem0.Store.Facts
  alias Mem0.Store.Scopes

  setup do
    LLM.Stub.start!()
    Embedder.Stub.start!()

    {:ok, scope} = Scopes.create(%{user: "u", project: "/code/widget", session: "session-1"})

    {:ok, first} =
      Diffs.create(%{
        file: "lib/foo.ex",
        diff: "-  case fetch(x) do\n+  with {:ok, y} <- fetch(x) do",
        scope_id: scope.id
      })

    {:ok, second} =
      Diffs.create(%{
        file: "lib/bar.ex",
        diff: "-  IO.inspect(x)\n+  Logger.debug(x)",
        scope_id: scope.id
      })

    %{scope: scope, first: first, second: second}
  end

  describe "process_scope/1" do
    test "extracts, stores and embeds the guidelines of every diff past the watermark",
         %{scope: scope, first: first, second: second} do
      set_guidelines_reply(["Prefer with over case"])

      assert {:ok, _facts, diffs} = Processor.Diffs.process_scope(scope.id)
      assert Enum.map(diffs, & &1.id) == [first.id, second.id]

      assert [fact] = Facts.list()
      assert fact.fact == "Prefer with over case"
      assert fact.scope_id == scope.id
      refute fact.embedding_768 == nil

      assert Scopes.get(scope.id).last_extracted_diff_id == second.id
    end

    test "a batch holding no guideline still moves the watermark, in one call",
         %{scope: scope, second: second} do
      set_guidelines_reply([])

      assert {:ok, [], [_one, _two]} = Processor.Diffs.process_scope(scope.id)

      assert Facts.list() == []
      assert [%{messages: [%{content: prompt}]}] = LLM.Stub.calls()
      assert prompt =~ "fetch(x)"
      assert prompt =~ "Logger.debug"
      assert Scopes.get(scope.id).last_extracted_diff_id == second.id
    end

    test "a size cap splits the pass into several batches", %{scope: scope, second: second} do
      set_guidelines_reply([])

      assert {:ok, [], [_one, _two]} = Processor.Diffs.process_scope(scope.id, max_batch_chars: 1)

      assert [_first_call, _second_call] = LLM.Stub.calls()
      assert Scopes.get(scope.id).last_extracted_diff_id == second.id
    end

    test "a second pass over an unchanged scope extracts nothing", %{scope: scope} do
      set_guidelines_reply([])

      assert {:ok, [], [_one, _two]} = Processor.Diffs.process_scope(scope.id)
      assert {:ok, [], []} = Processor.Diffs.process_scope(scope.id)

      assert [_only_call] = LLM.Stub.calls()
    end

    test "an extraction failure stops the pass and leaves the watermark", %{scope: scope} do
      LLM.Stub.set({:error, {:http_error, 500, %{}}})

      assert {:error, {:http_error, 500, _body}} = Processor.Diffs.process_scope(scope.id)

      assert Facts.list() == []
      assert Embedder.Stub.calls() == []
      assert Scopes.get(scope.id).last_extracted_diff_id == nil
    end

    test "a failure on a later batch keeps the earlier ones done and resumes there",
         %{scope: scope, first: first, second: second} do
      # one diff per batch, so the second diff's text is only in the second request
      LLM.Stub.set(fn %{messages: [%{content: prompt}]}, _opts ->
        if String.contains?(prompt, "Logger.debug"),
          do: {:error, :boom},
          else: {:ok, LLM.Stub.response(Jason.encode!(%{"guidelines" => []}))}
      end)

      assert {:error, :boom} = Processor.Diffs.process_scope(scope.id, max_batch_chars: 1)
      assert Scopes.get(scope.id).last_extracted_diff_id == first.id

      set_guidelines_reply([])

      assert {:ok, [], [only]} = Processor.Diffs.process_scope(scope.id)
      assert only.id == second.id
      assert Scopes.get(scope.id).last_extracted_diff_id == second.id
    end

    test "a developer change brings the agent's earlier diffs on the file along as context",
         %{scope: scope} do
      set_guidelines_reply([])
      assert {:ok, [], [_one, _two]} = Processor.Diffs.process_scope(scope.id)

      {:ok, _older} =
        Diffs.create(%{file: "lib/baz.ex", diff: "-old()\n+older()", origin: :manual, scope_id: scope.id})

      {:ok, _agent} =
        Diffs.create(%{file: "lib/baz.ex", diff: "-older()\n+agent()", origin: :agent, scope_id: scope.id})

      assert {:ok, [], [_older, _agent]} = Processor.Diffs.process_scope(scope.id)

      {:ok, manual} =
        Diffs.create(%{file: "lib/baz.ex", diff: "-agent()\n+mine()", origin: :manual, scope_id: scope.id})

      # only the new diff is the batch; the agent's diff rides along, the
      # developer's older one does not
      assert {:ok, [], [only]} = Processor.Diffs.process_scope(scope.id)
      assert only.id == manual.id

      assert [_setup, _older_and_agent, %{messages: [%{content: prompt}]}] = LLM.Stub.calls()
      assert prompt =~ "+agent()"
      assert prompt =~ "+mine()"
      refute prompt =~ "+older()"
      assert Scopes.get(scope.id).last_extracted_diff_id == manual.id
    end

    test "a scope nobody stored is an error", %{scope: scope} do
      assert {:error, :scope_does_not_exist} = Processor.Diffs.process_scope(scope.id + 1)
    end
  end

  describe "process_diffs/0" do
    test "processes every stale scope, then finds nothing to do" do
      set_guidelines_reply([])

      assert {[{[], [_one, _two]}], []} = Processor.Diffs.process_diffs()
      assert {[], []} = Processor.Diffs.process_diffs()
    end
  end

  # Answers the extractor with guidelines and the reconciler with ADD, told
  # apart by the schema each asks for.
  defp set_guidelines_reply(guidelines) do
    LLM.Stub.set(fn
      %{schema: %{"properties" => %{"guidelines" => _}}}, _opts ->
        {:ok, LLM.Stub.response(Jason.encode!(%{"guidelines" => guidelines}))}

      _reconcile, _opts ->
        {:ok, LLM.Stub.response(Jason.encode!(%{"event" => "ADD", "id" => nil, "reason" => "new"}))}
    end)
  end
end
