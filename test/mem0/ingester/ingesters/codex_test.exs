defmodule Mem0.Ingester.CodexTest do
  @moduledoc """
  The contract of the Codex ingester, exercised through
  `Mem0.Ingester.decode_transcript/2` and the behaviour callbacks it is built
  from: conversation lives in `response_item` message payloads, the scope in
  the `session_meta` record, machinery everywhere else.
  """
  use ExUnit.Case, async: true

  alias Mem0.Ingester
  alias Mem0.Ingester.Codex

  @timestamp "2026-08-24T09:00:00.000Z"

  describe "decode_transcript/2 with Codex" do
    test "keeps user and final assistant answers, in file order, with identity and time" do
      transcript =
        transcript([
          meta(),
          record(message("user", "why is the build slow?")),
          record(
            message("assistant", "The PLT is being rebuilt.", %{
              "id" => "msg_abc",
              "phase" => "final_answer"
            })
          )
        ])

      assert {:ok, scope, [user, assistant]} = Ingester.decode_transcript(transcript, Codex)
      assert scope == %{project: "git@github.com:example/widget.git", session: "session-1"}
      assert %{role: "user", content: "why is the build slow?", id: nil} = user
      assert %{role: "assistant", id: "msg_abc"} = assistant
      assert user.timestamp == ~U[2026-08-24 09:00:00.000Z]
    end

    test "machinery produces no message and no error" do
      records = [
        meta(),
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

      assert {:ok, _scope, []} = Ingester.decode_transcript(transcript(records), Codex)
    end

    test "an assistant message that is not the final answer is machinery" do
      records = [
        meta(),
        record(message("assistant", "draft thinking")),
        record(message("assistant", "the answer", %{"phase" => "final_answer"}))
      ]

      assert {:ok, _scope, [%{content: "the answer"}]} =
               Ingester.decode_transcript(transcript(records), Codex)
    end

    test "text blocks join and non-text blocks contribute nothing" do
      blocks = [
        %{"type" => "input_text", "text" => "look at this"},
        %{"type" => "input_image", "image_url" => "data:..."},
        %{"type" => "input_text", "text" => "what is wrong?"}
      ]

      transcript =
        transcript([
          meta(),
          record(%{"type" => "message", "role" => "user", "content" => blocks})
        ])

      assert {:ok, _scope, [message]} = Ingester.decode_transcript(transcript, Codex)
      assert message.content == "look at this\nwhat is wrong?"
    end

    test "a record without a readable timestamp fails the transcript" do
      records = [meta(), Map.delete(record(message("user", "hello")), "timestamp")]

      assert {:error, :message_extract_failed} =
               Ingester.decode_transcript(transcript(records), Codex)
    end

    test "a line that does not decode fails the transcript, first failure wins" do
      transcript = Enum.join([Jason.encode!(meta()), "{not json", "{"], "\n")

      assert {:error, {:invalid_line, 2}} = Ingester.decode_transcript(transcript, Codex)
    end
  end

  describe "scope/1" do
    test "prefers the repository url over the working directory" do
      assert {:ok, %{project: "git@github.com:example/widget.git", session: "session-1"}} =
               Codex.scope([meta()])
    end

    test "falls back to the working directory when there is no git remote" do
      meta = put_in(meta(), ["payload", "git"], nil)

      assert {:ok, %{project: "/Users/example/Code/widget", session: "session-1"}} =
               Codex.scope([meta])
    end

    test "a repeated identical session_meta still resolves to one scope" do
      assert {:ok, %{session: "session-1"}} = Codex.scope([meta(), meta()])
    end

    test "no session_meta means no project" do
      assert {:error, :no_project} = Codex.scope([record(message("user", "hi"))])
    end

    test "a session_meta without an id has no session" do
      meta = put_in(meta(), ["payload", "id"], nil)

      assert {:error, :no_session_found} = Codex.scope([meta])
    end

    test "two conflicting session_metas are ambiguous" do
      other = put_in(meta(), ["payload", "id"], "session-2")

      assert {:error, :ambiguous_scope} = Codex.scope([meta(), other])
    end
  end

  defp transcript(records), do: Enum.map_join(records, "\n", &Jason.encode!/1)

  defp meta do
    %{
      "timestamp" => @timestamp,
      "type" => "session_meta",
      "payload" => %{
        "id" => "session-1",
        "cwd" => "/Users/example/Code/widget",
        "git" => %{"repository_url" => "git@github.com:example/widget.git"}
      }
    }
  end

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
