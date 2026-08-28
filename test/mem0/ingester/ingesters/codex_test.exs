defmodule Mem0.Ingester.CodexTest do
  @moduledoc """
  The Codex rollout format, as measured on the local corpus: conversation in
  `response_item` message payloads, machinery everywhere else, synthetic
  content injected into the user turn behind known wrappers.
  """
  use ExUnit.Case, async: true

  alias Mem0.Ingester.Codex

  doctest Codex

  @timestamp "2026-08-24T09:00:00.000Z"

  describe "ingest/1" do
    test "keeps user and assistant, in file order, with identity and time" do
      transcript =
        transcript([
          record(message("user", "why is the build slow?")),
          record(message("assistant", "The PLT is being rebuilt.", %{"id" => "msg_abc"}))
        ])

      assert {:ok, [user, assistant]} = Codex.ingest(transcript)
      assert %{role: "user", content: "why is the build slow?", id: nil} = user
      assert %{role: "assistant", id: "msg_abc"} = assistant
      assert user.timestamp == ~U[2026-08-24 09:00:00.000000Z]
    end

    test "text blocks join and non-text blocks contribute nothing" do
      blocks = [
        %{"type" => "input_text", "text" => "look at this"},
        %{"type" => "input_image", "image_url" => "data:..."},
        %{"type" => "input_text", "text" => "what is wrong?"}
      ]

      transcript =
        transcript([record(%{"type" => "message", "role" => "user", "content" => blocks})])

      assert {:ok, [message]} = Codex.ingest(transcript)
      assert message.content == "look at this\nwhat is wrong?"
    end

    test "machinery produces no message and no error" do
      records = [
        %{"timestamp" => @timestamp, "type" => "session_meta", "payload" => %{"id" => "s"}},
        %{"timestamp" => @timestamp, "type" => "turn_context", "payload" => %{}},
        %{
          "timestamp" => @timestamp,
          "type" => "event_msg",
          "payload" => %{"type" => "token_count"}
        },
        record(%{"type" => "reasoning", "summary" => []}),
        record(%{"type" => "function_call", "name" => "shell"}),
        record(message("developer", "You are assessing a request."))
      ]

      assert {:ok, []} = Codex.ingest(transcript(records))
    end

    test "wholly synthetic user turns drop" do
      records = [
        record(
          message("user", "<environment_context>\n<cwd>/Users/x</cwd>\n</environment_context>")
        ),
        record(message("user", "<turn_aborted>\nThe user interrupted.\n</turn_aborted>")),
        record(message("user", "<recommended_plugins>\n- Figma\n</recommended_plugins>"))
      ]

      assert {:ok, []} = Codex.ingest(transcript(records))
    end

    test "the image wrapper strips and the person's own words survive" do
      text = ~s(<image name=[Image #1] path="/tmp/shot.png">\n</image>\n[Image #1] looks weird)

      assert {:ok, [message]} = Codex.ingest(transcript([record(message("user", text))]))
      assert message.content == "[Image #1] looks weird"
    end

    test "a dangling open wrapper strips to end-of-input" do
      text = "here is my question<environment_context>\n<cwd>/Users/x</cwd>"

      assert {:ok, [message]} = Codex.ingest(transcript([record(message("user", text))]))
      assert message.content == "here is my question"
    end

    test "wrappers stay verbatim in assistant text" do
      text = "Codex injects <environment_context> into the first user turn."

      assert {:ok, [message]} = Codex.ingest(transcript([record(message("assistant", text))]))
      assert message.content == text
    end

    test "a record without a readable timestamp is dropped, not invented" do
      records = [
        Map.delete(record(message("user", "hello")), "timestamp"),
        record(message("user", "hello"), %{"timestamp" => "not a time"})
      ]

      assert {:ok, []} = Codex.ingest(transcript(records))
    end

    test "a decodable non-record line is dropped, not fatal" do
      transcript = Enum.join([Jason.encode!(record(message("user", "hello"))), "5", "[]"], "\n")

      assert {:ok, [%{content: "hello"}]} = Codex.ingest(transcript)
    end

    test "a line that does not decode fails the transcript, first failure wins" do
      transcript =
        Enum.join([Jason.encode!(record(message("user", "hi"))), "{not json", "{"], "\n")

      assert {:error, {:invalid_line, 2}} = Codex.ingest(transcript)
    end
  end

  defp transcript(records), do: Enum.map_join(records, "\n", &Jason.encode!/1)

  # Shaped the way a rollout line is shaped. The `overrides` map is merged
  # last so a test can delete or corrupt any field.
  defp record(payload, overrides \\ %{}) do
    Map.merge(
      %{"timestamp" => @timestamp, "type" => "response_item", "payload" => payload},
      overrides
    )
  end

  defp message(role, text, overrides \\ %{}) do
    block_type = if role == "assistant", do: "output_text", else: "input_text"

    Map.merge(
      %{
        "type" => "message",
        "role" => role,
        "content" => [%{"type" => block_type, "text" => text}]
      },
      overrides
    )
  end
end
