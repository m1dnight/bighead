defmodule Mem0.IngestTest do
  @moduledoc """
  The boundary's two jobs are validation and identity, and identity is the one
  with a security consequence: `Scope.user_id` separates one person's memories
  from another's, so the tests that matter most here are the ones showing it
  cannot be moved from the request body.
  """
  use ExUnit.Case, async: true

  import Mem0.TranscriptFixtures

  alias Mem0.Ingest

  describe "identity comes from the server" do
    test "user_id is the argument, whatever the payload claims" do
      payload =
        "plain_exchange"
        |> entries()
        |> stop_payload()
        |> Map.merge(%{"user_id" => "someone-else", "userId" => "someone-else"})

      assert {:ok, [message | _rest], _drops} = Ingest.receive(payload, "christophe")
      assert message.scope.user_id == "christophe"
    end

    test "app_id is the basename of the client's cwd" do
      payload = "plain_exchange" |> entries() |> stop_payload(cwd: "/Users/example/Code/widget")

      assert {:ok, [message | _rest], _drops} = Ingest.receive(payload, "christophe")
      assert message.scope.app_id == "widget"
    end

    test "run_id is the client's session id" do
      payload = "plain_exchange" |> entries() |> stop_payload(session_id: "session-9")

      assert {:ok, [message | _rest], _drops} = Ingest.receive(payload, "christophe")
      assert message.scope.run_id == "session-9"
    end

    test "a blank cwd lands on the user-global scope rather than raising" do
      payload = "plain_exchange" |> entries() |> stop_payload(cwd: "")

      assert {:ok, [message | _rest], _drops} = Ingest.receive(payload, "christophe")
      assert message.scope.app_id == nil
    end

    test "a missing cwd or session id is nil, not a failure" do
      payload =
        "plain_exchange"
        |> entries()
        |> stop_payload()
        |> Map.drop(["cwd", "session_id"])

      assert {:ok, [message | _rest], _drops} = Ingest.receive(payload, "christophe")
      assert {message.scope.app_id, message.scope.run_id} == {nil, nil}
    end
  end

  describe "default_user_id/0" do
    test "falls back rather than raising when nothing is configured" do
      assert is_binary(Ingest.default_user_id())
      assert Ingest.default_user_id() != ""
    end
  end

  describe "the two lengths" do
    test "seq is absolute: the offset is total minus this batch" do
      payload = "plain_exchange" |> entries() |> stop_payload(offset: 40)

      assert {:ok, messages, _drops} = Ingest.receive(payload, "christophe")
      assert Enum.map(messages, & &1.seq) == [40, 41, 42, 43]
    end

    test "a batch whose length disagrees with its own count is rejected" do
      payload =
        "plain_exchange"
        |> entries()
        |> stop_payload()
        |> Map.put("transcript_length", 99)

      assert {:error, {:length_mismatch, 99, 4}} = Ingest.receive(payload, "christophe")
    end

    test "a total smaller than the batch is impossible and refused, not clamped" do
      payload =
        "plain_exchange"
        |> entries()
        |> stop_payload()
        |> Map.put("total_transcript_length", 1)

      assert {:error, {:invalid_offset, -3}} = Ingest.receive(payload, "christophe")
    end

    test "a payload with no counts cannot be numbered" do
      payload =
        "plain_exchange"
        |> entries()
        |> stop_payload()
        |> Map.drop(["transcript_length", "total_transcript_length"])

      assert {:error, :missing_transcript_length} = Ingest.receive(payload, "christophe")
    end
  end

  describe "payloads it will not use" do
    test "no entries at all" do
      assert {:error, :no_entries} = Ingest.receive(%{"hook_event_name" => "Stop"}, "christophe")
    end

    test "entries that are not a list" do
      payload = %{"entries" => %{"nope" => true}, "transcript_length" => 0}

      assert {:error, :invalid_entries} = Ingest.receive(payload, "christophe")
    end

    test "a payload that is not a map" do
      assert {:error, :invalid_payload} = Ingest.receive("garbage", "christophe")
    end

    test "an empty batch is valid and parses to nothing" do
      assert {:ok, [], []} = Ingest.receive(stop_payload([]), "christophe")
    end

    test "entries of garbage are dropped, not raised on" do
      payload = stop_payload([nil, "line", 42, %{"type" => "user"}])

      assert {:ok, [], drops} = Ingest.receive(payload, "christophe")
      assert drops == [:malformed, :malformed, :malformed, :malformed]
    end
  end

  describe "the answer the transcript does not have yet" do
    test "is rebuilt from last_assistant_message" do
      payload =
        "plain_exchange"
        |> entries()
        |> Enum.drop(-1)
        |> stop_payload(
          last_assistant_message: "Understood.",
          prompt_id: "turn-7",
          hook_at: "2026-08-24T09:01:15Z"
        )

      assert {:ok, messages, _drops} = Ingest.receive(payload, "christophe")

      answer = List.last(messages)
      assert answer.role == :assistant
      assert answer.content == "Understood."
      assert answer.id == "pending:turn-7"
      assert answer.said_at == ~U[2026-08-24 09:01:15Z]
    end

    test "sits after every message the batch did contain" do
      payload =
        "plain_exchange"
        |> entries()
        |> Enum.drop(-1)
        |> stop_payload(offset: 40, last_assistant_message: "Understood.")

      assert {:ok, messages, _drops} = Ingest.receive(payload, "christophe")
      assert Enum.map(messages, & &1.seq) == [40, 41, 42, 43]
      assert messages |> List.last() |> Map.get(:content) == "Understood."
    end

    test "carries the same scope as the rest of the batch" do
      payload =
        "plain_exchange"
        |> entries()
        |> Enum.drop(-1)
        |> stop_payload(cwd: "/Users/example/Code/widget", last_assistant_message: "Understood.")

      assert {:ok, messages, _drops} = Ingest.receive(payload, "christophe")
      assert messages |> List.last() |> Map.get(:scope) |> Map.get(:app_id) == "widget"
    end

    # The next turn's tail carries the genuine entry. Rebuilding it again there
    # would duplicate the turn's answer in every later batch.
    test "is skipped once the real entry has landed" do
      payload =
        "plain_exchange"
        |> entries()
        |> stop_payload(last_assistant_message: "Understood.")

      assert {:ok, messages, _drops} = Ingest.receive(payload, "christophe")
      assert length(messages) == 4
      assert Enum.count(messages, &(&1.content == "Understood.")) == 1
      assert messages |> List.last() |> Map.get(:id) == "a1000000-0000-4000-8000-000000000004"
    end

    test "an undatable answer is dropped rather than dated wrongly" do
      for hook_at <- [nil, "yesterday"] do
        payload =
          "plain_exchange"
          |> entries()
          |> Enum.drop(-1)
          |> stop_payload(last_assistant_message: "Understood.", hook_at: hook_at)

        assert {:ok, messages, _drops} = Ingest.receive(payload, "christophe")
        assert length(messages) == 3
      end
    end

    test "an answer with no prompt to attribute it to is dropped" do
      payload =
        "plain_exchange"
        |> entries()
        |> Enum.drop(-1)
        |> stop_payload(last_assistant_message: "Understood.", prompt_id: nil)

      assert {:ok, messages, _drops} = Ingest.receive(payload, "christophe")
      assert length(messages) == 3
    end

    test "a payload with no answer at all adds nothing" do
      for text <- [nil, "", "   "] do
        payload =
          "plain_exchange"
          |> entries()
          |> Enum.drop(-1)
          |> stop_payload(last_assistant_message: text)

        assert {:ok, messages, _drops} = Ingest.receive(payload, "christophe")
        assert length(messages) == 3
      end
    end
  end

  describe "observability" do
    test "the event carries counts and identifiers, and no content" do
      handler = attach([:mem0, :ingest, :received])

      payload =
        "tool_heavy" |> entries() |> stop_payload(offset: 10, cwd: "/Users/example/widget")

      assert {:ok, messages, drops} = Ingest.receive(payload, "christophe")

      assert_receive {^handler, measurements, metadata}

      assert measurements.entries == 6
      assert measurements.messages == length(messages)
      assert measurements.dropped == length(drops)
      assert is_integer(measurements.duration)

      assert metadata.user_id == "christophe"
      assert metadata.app_id == "widget"
      assert metadata.hook_event == "Stop"

      # Bucketed by reason, and by the *type string* for an unsupported type: an
      # aggregate would bury a genuinely new type under the known-constant
      # majority rule 1 rejects on every batch.
      assert metadata.drops == %{
               "no_text" => 1,
               "tool_result" => 1,
               "unsupported_type:attachment" => 1,
               "unsupported_type:file-history-snapshot" => 1
             }

      refute_content_in(metadata)
      refute_content_in(measurements)
    end
  end

  # Telemetry metadata is a map of ids and counts. Anything that looks like
  # transcript prose in there is the redaction policy being broken.
  defp refute_content_in(map) do
    for {_key, value} <- map, is_binary(value) do
      refute String.contains?(value, " ")
    end
  end

  defp attach(event) do
    ref = make_ref()
    test = self()

    :telemetry.attach(
      {__MODULE__, ref},
      event,
      fn ^event, measurements, metadata, _config ->
        send(test, {ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

    ref
  end
end
