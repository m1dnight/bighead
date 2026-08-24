defmodule Mem0Web.HooksControllerTest do
  @moduledoc """
  The hooks are wired into a live session, so the property under test is mostly
  negative: whatever arrives, this answers 200 with the exact keys Claude Code
  reads, and never with a 5xx. `UserPromptSubmit` blocks the turn that fired it,
  so a failure here stalls a real session.

  These use `Mem0Web.ConnCase`, which sets `@moduletag :db` and checks out a
  sandbox connection even though nothing below touches the database. That is
  accepted rather than worked around: a repo-less conn case is a second thing to
  keep in step with the first, for tests that `mix test` runs anyway.
  """
  use Mem0Web.ConnCase, async: true

  import Mem0.TranscriptFixtures

  describe "POST /hooks/stop" do
    test "answers with the exact key names Claude Code reads", %{conn: conn} do
      body = "plain_exchange" |> entries() |> stop_payload()

      conn = post(conn, ~p"/hooks/stop", body)

      assert json_response(conn, 200) == %{"hookSpecificOutput" => %{"hookEventName" => "Stop"}}
    end

    test "no decision field: it would send Claude back to work", %{conn: conn} do
      body = "plain_exchange" |> entries() |> stop_payload()

      conn = post(conn, ~p"/hooks/stop", body)

      refute Map.has_key?(json_response(conn, 200), "decision")
    end

    # The route is the only place that resolves `user_id`, so the exit criterion
    # is checked here rather than only in `Mem0.IngestTest`. Telemetry is the
    # observation seam: the controller discards the parse result.
    test "user_id cannot be set from the request body", %{conn: conn} do
      handler = attach(&(&1.run_id == "route-identity"))

      body =
        "plain_exchange"
        |> entries()
        |> stop_payload(session_id: "route-identity")
        |> Map.put("user_id", "someone-else")

      post(conn, ~p"/hooks/stop", body)

      assert_receive {^handler, measurements, metadata}
      assert measurements.messages == 4
      assert metadata.user_id == Mem0.Ingest.default_user_id()
      refute metadata.user_id == "someone-else"
    end

    test "200 on a body of garbage", %{conn: conn} do
      for body <- [
            %{},
            %{"entries" => "not a list"},
            %{"entries" => [nil, 1, "two"], "transcript_length" => 3},
            %{"entries" => [%{"type" => "user"}], "transcript_length" => 99},
            %{"hook_event_name" => "Stop", "cwd" => 42, "session_id" => %{"a" => 1}}
          ] do
        assert conn |> post(~p"/hooks/stop", body) |> json_response(200)
      end
    end

    test "200 on a batch that produced nothing", %{conn: conn} do
      body = stop_payload([])

      assert conn |> post(~p"/hooks/stop", body) |> json_response(200)
    end

    test "a body that is not JSON at all is a 400, never a 5xx", %{conn: conn} do
      assert_error_sent 400, fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/hooks/stop", "{not json")
      end
    end
  end

  describe "POST /hooks/user-prompt-submit" do
    test "answers with the exact key names Claude Code reads", %{conn: conn} do
      body = %{
        "hook_event_name" => "UserPromptSubmit",
        "session_id" => "session-1",
        "cwd" => "/Users/example/Code/widget",
        "prompt" => "i prefer tabs over spaces"
      }

      conn = post(conn, ~p"/hooks/user-prompt-submit", body)

      assert json_response(conn, 200) == %{
               "hookSpecificOutput" => %{
                 "hookEventName" => "UserPromptSubmit",
                 "additionalContext" => "",
                 "sessionTitle" => "i prefer tabs over spaces"
               }
             }
    end

    test "no decision field: it would erase the prompt", %{conn: conn} do
      conn = post(conn, ~p"/hooks/user-prompt-submit", %{"prompt" => "hello"})

      refute Map.has_key?(json_response(conn, 200), "decision")
    end

    test "the session title is the prompt's first line, truncated", %{conn: conn} do
      prompt = String.duplicate("a", 80) <> "\nsecond line"

      conn = post(conn, ~p"/hooks/user-prompt-submit", %{"prompt" => prompt})

      title = get_in(json_response(conn, 200), ["hookSpecificOutput", "sessionTitle"])

      assert title == String.duplicate("a", 60)
    end

    test "200 with a fallback title on a body with no usable prompt", %{conn: conn} do
      for body <- [%{}, %{"prompt" => ""}, %{"prompt" => "   "}, %{"prompt" => 42}] do
        response = conn |> post(~p"/hooks/user-prompt-submit", body) |> json_response(200)

        assert get_in(response, ["hookSpecificOutput", "sessionTitle"]) == "mem0 hook session"
      end
    end

    test "it ingests nothing: the transcript reaches mem0 through Stop", %{conn: conn} do
      handler = attach(&(&1.hook_event == "UserPromptSubmit"))

      post(conn, ~p"/hooks/user-prompt-submit", %{"prompt" => "hello"})

      refute_receive {^handler, _measurements, _metadata}
    end
  end

  # Telemetry handlers are global, so a concurrent test's batch would otherwise
  # arrive here too. `match` narrows the handler to this test's own event.
  defp attach(match) do
    ref = make_ref()
    test = self()
    event = [:mem0, :ingest, :received]

    :telemetry.attach(
      {__MODULE__, ref},
      event,
      fn ^event, measurements, metadata, _config ->
        if match.(metadata), do: send(test, {ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

    ref
  end
end
