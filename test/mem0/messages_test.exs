defmodule Mem0.MessagesTest do
  @moduledoc """
  The round trip is the phase. Everything else here is a guard on it: that a
  second put does not double it, that the read is ordered and scoped, and that
  the column nothing fills yet reads back as NULL rather than as a zero vector.
  """

  use Mem0.DataCase, async: true
  use Mem0.CoreFixtures

  alias Mem0.Messages
  alias Mem0.Messages.Row

  # Nonzero in every position, so a column that truncated to seconds or to
  # milliseconds would show up as an inequality rather than as a coincidence.
  @said_at DateTime.add(at(0), 1_123_456, :microsecond)

  describe "put/1 and for_run/1" do
    test "a batch reads back as the messages that went in" do
      scope = scope()

      # All three roles, because the role maps in `Row` are the one place the
      # round trip stops being a copy and starts being a translation.
      sent =
        for {role, content, seq} <- [
              {:system, "Be brief.", 1},
              {:user, "Where do I live?", 2},
              {:assistant, "San Francisco.", 3}
            ] do
          message(
            id: "msg-#{seq}",
            scope: scope,
            role: role,
            content: content,
            seq: seq,
            said_at: @said_at
          )
        end

      assert {:ok, 3} = Messages.put(sent)
      assert Messages.for_run(scope) == sent
    end

    test "microseconds on said_at survive the round trip" do
      scope = scope()

      assert {:ok, 1} = Messages.put([message(scope: scope, said_at: @said_at)])
      assert [read_back] = Messages.for_run(scope)
      assert read_back.said_at == @said_at
      assert read_back.said_at.microsecond == {123_456, 6}
    end

    test "a millisecond-stamped transcript timestamp round-trips" do
      scope = scope()
      {:ok, from_transcript, 0} = DateTime.from_iso8601("2026-08-25T06:59:38.884Z")

      sent = message(scope: scope, said_at: from_transcript)

      assert {:ok, 1} = Messages.put([sent])
      assert [read_back] = Messages.for_run(scope)
      assert read_back == sent
      assert read_back.said_at.microsecond == {884_000, 6}
    end

    test "a scope with no app or run reads back with both still nil" do
      scope = scope(app_id: nil, run_id: nil)

      assert {:ok, 1} = Messages.put([message(scope: scope)])
      assert [read_back] = Messages.for_run(scope)
      assert read_back.scope == scope
      assert {nil, nil} == {read_back.scope.app_id, read_back.scope.run_id}
    end

    test "putting the same batch twice is a no-op the second time" do
      scope = scope()

      sent = [
        message(id: "msg-1", scope: scope, seq: 1),
        message(id: "msg-2", scope: scope, seq: 2)
      ]

      assert {:ok, 2} = Messages.put(sent)
      after_first = Messages.for_run(scope)

      assert {:ok, 0} = Messages.put(sent)
      assert Messages.for_run(scope) == after_first
    end

    test "for_run/1 orders by seq, not by insertion order" do
      scope = scope()

      Messages.put([
        message(id: "msg-3", scope: scope, seq: 3),
        message(id: "msg-1", scope: scope, seq: 1),
        message(id: "msg-2", scope: scope, seq: 2)
      ])

      assert [1, 2, 3] == Enum.map(Messages.for_run(scope), & &1.seq)
    end

    test "a second run in the same app is invisible to the first run's read" do
      mine = scope(run_id: "session-1")
      theirs = scope(run_id: "session-2")

      Messages.put([
        message(id: "msg-mine", scope: mine),
        message(id: "msg-theirs", scope: theirs)
      ])

      assert ["msg-mine"] == Enum.map(Messages.for_run(mine), & &1.id)
      assert ["msg-theirs"] == Enum.map(Messages.for_run(theirs), & &1.id)
    end

    test "an empty batch issues no query" do
      attach_query_telemetry()

      assert {:ok, 0} = Messages.put([])
      refute_received :repo_query

      # The refutation above is only worth something if the handler fires at
      # all, so make it fire.
      assert {:ok, 1} = Messages.put([message()])
      assert_received :repo_query
    end

    test "the embedding column is created and left NULL" do
      assert {:ok, 1} = Messages.put([message(id: "msg-1")])

      assert [nil] == Repo.all(from row in Row, select: row.embedding)
    end
  end

  describe "lines_seen/1" do
    test "a run nothing was stored for has seen nothing" do
      assert 0 == Messages.lines_seen(scope())
    end

    test "counts every line up to the last one stored, gaps included" do
      scope = scope()

      Messages.put([
        message(id: "msg-40", scope: scope, seq: 40),
        message(id: "msg-42", scope: scope, seq: 42)
      ])

      # Lines 0..42 are accounted for, whether or not each one became a message.
      assert 43 == Messages.lines_seen(scope)
    end

    test "it follows the highest seq, not the last row inserted" do
      scope = scope()

      Messages.put([
        message(id: "msg-9", scope: scope, seq: 9),
        message(id: "msg-1", scope: scope, seq: 1)
      ])

      assert 10 == Messages.lines_seen(scope)
    end

    test "another run in the same app does not raise this run's count" do
      mine = scope(run_id: "session-1")
      theirs = scope(run_id: "session-2")

      Messages.put([message(id: "msg-theirs", scope: theirs, seq: 99)])

      assert 0 == Messages.lines_seen(mine)
    end
  end

  @doc false
  def send_query_event(_event, _measurements, _metadata, pid), do: send(pid, :repo_query)

  # An external capture rather than a local one: `:telemetry` logs a warning
  # about the performance of local-function handlers, and a warning under
  # `config :logger, level: :warning` is noise in an otherwise silent suite.
  defp attach_query_telemetry do
    handler_id = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:mem0, :repo, :query],
        &__MODULE__.send_query_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
