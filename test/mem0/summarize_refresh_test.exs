defmodule Mem0.SummarizeRefreshTest do
  @moduledoc """
  The wiring, not the call: `refresh/2` is policy composed with both stores
  and the port, and this is the first suite that needs all three at once.

  `async: false`, unlike the store suites: `refresh_async/2` runs on a task
  under the application's `Task.Supervisor`, and only the sandbox's shared
  mode lets that process use this test's connection. The stub needs no such
  favour — `Mem0.PortStub` already follows `$callers` into spawned tasks.
  """
  use Mem0.DataCase, async: false
  use Mem0.CoreFixtures

  alias Mem0.LLM
  alias Mem0.Messages
  alias Mem0.Summaries
  alias Mem0.Summarize

  # One past `Mem0.Core.Summary`'s default max_lag: the smallest run that
  # deserves a summary.
  @enough 11

  setup do
    LLM.Stub.start!(reply: {:ok, LLM.Stub.response(~s({"summary": "The user uses Elixir."}))})
    :ok
  end

  describe "refresh/2" do
    test "an empty run is :fresh, not an error" do
      assert Summarize.refresh(scope()) == :fresh
      assert LLM.Stub.calls() == []
    end

    test "a young run is :fresh and spends no call" do
      scope = scope()
      store(scope, 1..(@enough - 1))

      assert Summarize.refresh(scope) == :fresh
      assert LLM.Stub.calls() == []
      assert Summaries.latest(scope) == nil
    end

    test "gapped seqs count as messages, not as line distance" do
      # Three messages scattered across sixty transcript lines: seq
      # subtraction would call this stale, the message count does not.
      scope = scope()
      store(scope, [10, 30, 60])

      assert Summarize.refresh(scope) == :fresh
      assert LLM.Stub.calls() == []
    end

    test "a run past max_lag earns its first summary, stored and watermarked" do
      scope = scope()
      store(scope, 1..@enough)

      assert {:ok, summary} = Summarize.refresh(scope)
      assert summary.through_seq == @enough
      assert summary.text == "The user uses Elixir."
      assert Summaries.latest(scope) == summary
    end

    test "a summary within max_lag of the head stays latest untouched" do
      scope = scope()
      store(scope, 1..@enough)
      {:ok, first} = Summarize.refresh(scope)
      store(scope, (@enough + 1)..(@enough + 5))

      assert Summarize.refresh(scope) == :fresh
      assert Summaries.latest(scope) == first
    end

    test "a stale summary regenerates over the whole history" do
      scope = scope()
      store(scope, 1..@enough)
      {:ok, _first} = Summarize.refresh(scope)
      store(scope, (@enough + 1)..(2 * @enough))

      assert {:ok, second} = Summarize.refresh(scope)
      assert second.through_seq == 2 * @enough
      assert Summaries.latest(scope) == second

      # Regeneration, not an increment: the second request re-reads everything.
      assert [_first_request, request] = LLM.Stub.calls()
      assert [%{content: content}] = request.messages
      assert content =~ "message 1"
      assert content =~ "message #{2 * @enough}"
    end

    test "an LLM error leaves the previous summary latest" do
      scope = scope()
      store(scope, 1..@enough)
      {:ok, first} = Summarize.refresh(scope)
      store(scope, (@enough + 1)..(2 * @enough))
      LLM.Stub.set({:error, {:http_error, 429, %{}}})

      assert Summarize.refresh(scope) == {:error, {:http_error, 429, %{}}}
      assert Summaries.latest(scope) == first
    end

    test "a malformed reply leaves the previous summary latest" do
      scope = scope()
      store(scope, 1..@enough)
      {:ok, first} = Summarize.refresh(scope)
      store(scope, (@enough + 1)..(2 * @enough))
      LLM.Stub.set({:ok, LLM.Stub.response("Sure! Here's a summary:")})

      assert Summarize.refresh(scope) == {:error, :malformed_summary}
      assert Summaries.latest(scope) == first
    end
  end

  describe "refresh_async/2" do
    test "notifies the caller instead of making it sleep" do
      scope = scope()
      store(scope, 1..@enough)

      assert Summarize.refresh_async(scope, notify_pid: self()) == :ok

      assert_receive {:refreshed, ^scope, {:ok, summary}}, 1_000
      assert Summaries.latest(scope) == summary
    end

    test "emits outcome telemetry carrying identifiers, never text" do
      attach_refresh_telemetry()
      scope = scope()
      store(scope, 1..@enough)

      Summarize.refresh_async(scope)

      assert_receive {:refresh_event, measurements, metadata}, 1_000
      assert is_integer(measurements.duration)
      assert metadata.outcome == :regenerated
      assert metadata.user_id == scope.user_id
      assert metadata.run_id == scope.run_id
      # Identifiers and the outcome, nothing else: the summary's text must
      # not ride on an event the redaction policy cannot filter.
      assert map_size(metadata) == 4

      Summarize.refresh_async(scope)

      assert_receive {:refresh_event, _measurements, %{outcome: :fresh}}, 1_000
    end
  end

  defp store(scope, seqs) do
    {:ok, _count} =
      Messages.put(
        for seq <- seqs,
            do: message(id: "msg-#{seq}", scope: scope, content: "message #{seq}", seq: seq)
      )
  end

  @doc false
  def send_refresh_event(_event, measurements, metadata, pid),
    do: send(pid, {:refresh_event, measurements, metadata})

  # An external capture rather than a local one, for `Mem0.MessagesTest`'s
  # reason: `:telemetry` warns about local-function handlers.
  defp attach_refresh_telemetry do
    handler_id = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:mem0, :summarize, :refresh],
        &__MODULE__.send_refresh_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
