defmodule Mem0Web.HooksControllerTest do
  @moduledoc """
  The hooks are wired into a live session, so the property under test is mostly
  negative: whatever arrives, this answers 200 with the exact keys Claude Code
  reads, and never with a 5xx. `UserPromptSubmit` blocks the turn that fired it,
  so a failure here stalls a real session.

  These use `Mem0Web.ConnCase`, which sets `@moduletag :db` and checks out a
  sandbox connection. `backfill` and `lines_seen` need one for real;
  `user_prompt_submit` is along for the ride.

  `async: false`, unlike the store suites: every `POST /hooks/stop` spawns a
  refresh task under the application's `Task.Supervisor`, and only the
  sandbox's shared mode lets that process query. Each stop test then waits
  for its task's telemetry before ending, so the sandbox owner outlives the
  task's use of the connection.
  """
  use Mem0Web.ConnCase, async: false
  use Mem0.CoreFixtures

  import Mem0.TranscriptFixtures

  alias Mem0.Embedder
  alias Mem0.ExtractionState
  alias Mem0.Ingest
  alias Mem0.LLM
  alias Mem0.Memories
  alias Mem0.Messages
  alias Mem0.Summaries

  # `Stop` answers the same inert body whatever arrives — the refresh and the
  # pulse it fires report through the stores and telemetry, never through the
  # response. Every test that reaches the controller drains both events, so
  # the spawned tasks are done with the shared sandbox connection before the
  # test lets go of it. Both stubs start in setup because every `Stop` now
  # pulses: a pulse that finds messages reaches the LLM port whatever the
  # test is about.
  describe "POST /hooks/stop" do
    setup [:forward_refresh_telemetry, :forward_pulse_telemetry, :start_stubs]

    test "answers with the exact key names Claude Code reads", %{conn: conn} do
      body = "plain_exchange" |> entries() |> stop_payload()

      conn = post(conn, ~p"/hooks/stop", body)

      assert json_response(conn, 200) == %{"hookSpecificOutput" => %{"hookEventName" => "Stop"}}
      await_refresh(1)
      await_pulse(1)
    end

    test "no decision field: it would send Claude back to work", %{conn: conn} do
      body = "plain_exchange" |> entries() |> stop_payload()

      conn = post(conn, ~p"/hooks/stop", body)

      refute Map.has_key?(json_response(conn, 200), "decision")
      await_refresh(1)
      await_pulse(1)
    end

    test "a Stop pulse turns the fresh exchange into a memory and advances the cursor", %{
      conn: conn
    } do
      scope = posted_scope("stop-memory")

      assert {:ok, 2} =
               Messages.put([
                 message(id: "msg-1", scope: scope, content: "I use Elixir daily.", seq: 1),
                 message(id: "msg-2", scope: scope, role: :assistant, content: "Noted.", seq: 2)
               ])

      LLM.Stub.set(fn request, _opts ->
        if request.system == Extraction.system_prompt() do
          {:ok, LLM.Stub.response(~s({"facts": ["User uses Elixir"]}))}
        else
          {:ok, LLM.Stub.response(~s({"event": "ADD", "reason": "Nothing covers this."}))}
        end
      end)

      body = %{"session_id" => "stop-memory", "cwd" => "/Users/example/Code/widget"}

      assert conn |> post(~p"/hooks/stop", body) |> json_response(200)

      await_refresh(1)
      assert [:reconciled] = await_pulse(1)

      assert [%Memory{content: "User uses Elixir"}] =
               Memories.active(ScopeQuery.new(user_id: Ingest.default_user_id()))

      assert ExtractionState.through_seq(scope) == 2
    end

    test "a settled run past max_lag grows a summary", %{conn: conn} do
      LLM.Stub.set({:ok, LLM.Stub.response(~s({"summary": "A short session."}))})
      scope = posted_scope("stop-summary")

      assert {:ok, 11} =
               Messages.put(
                 for seq <- 1..11, do: message(id: "msg-#{seq}", scope: scope, seq: seq)
               )

      body = %{"session_id" => "stop-summary", "cwd" => "/Users/example/Code/widget"}

      assert conn |> post(~p"/hooks/stop", body) |> json_response(200)

      await_refresh(1)
      await_pulse(1)

      assert %Summary{through_seq: 11, text: "A short session."} = Summaries.latest(scope)
    end

    test "a quiet follow-up pulse regenerates nothing", %{conn: conn} do
      scope = posted_scope("stop-quiet")

      assert {:ok, 3} =
               Messages.put(
                 for seq <- 1..3, do: message(id: "msg-#{seq}", scope: scope, seq: seq)
               )

      body = %{"session_id" => "stop-quiet", "cwd" => "/Users/example/Code/widget"}

      assert conn |> post(~p"/hooks/stop", body) |> json_response(200)

      assert [:fresh] = await_refresh(1)
      await_pulse(1)
      assert Summaries.latest(scope) == nil
    end

    test "200 on a body of garbage", %{conn: conn} do
      bodies = [
        %{},
        %{"entries" => "not a list"},
        %{"entries" => [nil, 1, "two"], "transcript_length" => 3},
        %{"entries" => [%{"type" => "user"}], "transcript_length" => 99},
        %{"hook_event_name" => "Stop", "cwd" => 42, "session_id" => %{"a" => 1}}
      ]

      for body <- bodies do
        assert conn |> post(~p"/hooks/stop", body) |> json_response(200)
      end

      await_refresh(length(bodies))
      await_pulse(length(bodies))
    end

    test "200 on a batch that produced nothing", %{conn: conn} do
      body = stop_payload([])

      assert conn |> post(~p"/hooks/stop", body) |> json_response(200)
      await_refresh(1)
      await_pulse(1)
    end

    test "a body that is not JSON at all is a 400, never a 5xx", %{conn: conn} do
      assert_error_sent 400, fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/hooks/stop", "{not json")
      end

      # The parser raised before the router; no refresh or pulse was fired.
    end
  end

  # `stop_payload/2` defaults `cwd` to ".../Code/widget", and the routes take the
  # app id from its basename.
  defp posted_scope(run_id) do
    Scope.new(user_id: Ingest.default_user_id(), app_id: "widget", run_id: run_id)
  end

  describe "POST /hooks/backfill" do
    test "the messages it parsed are readable afterwards", %{conn: conn} do
      body = "plain_exchange" |> entries() |> stop_payload(session_id: "backfill-1")

      assert %{"stored" => 4} = conn |> post(~p"/hooks/backfill", body) |> json_response(200)

      stored = Messages.for_run(posted_scope("backfill-1"))

      assert [:user, :assistant, :user, :assistant] == Enum.map(stored, & &1.role)
      assert stored == Enum.sort_by(stored, & &1.seq)
    end

    test "posting the same slice again stores nothing and is not an error", %{conn: conn} do
      body = "plain_exchange" |> entries() |> stop_payload(session_id: "backfill-2")

      post(conn, ~p"/hooks/backfill", body)
      after_first = Messages.for_run(posted_scope("backfill-2"))

      assert %{"stored" => 0} = conn |> post(~p"/hooks/backfill", body) |> json_response(200)
      assert Messages.for_run(posted_scope("backfill-2")) == after_first
    end

    test "a slice is numbered from where it sits in the file, not from zero", %{conn: conn} do
      body =
        "plain_exchange" |> entries() |> stop_payload(session_id: "backfill-4", offset: 100)

      post(conn, ~p"/hooks/backfill", body)

      assert [100, 101, 102, 103] ==
               "backfill-4" |> posted_scope() |> Messages.for_run() |> Enum.map(& &1.seq)
    end

    test "200 with nothing stored on a payload it cannot parse", %{conn: conn} do
      for body <- [%{}, %{"entries" => "not a list"}, stop_payload([])] do
        assert %{"stored" => 0} = conn |> post(~p"/hooks/backfill", body) |> json_response(200)
      end
    end

    test "user_id cannot be set from the request body", %{conn: conn} do
      body =
        "plain_exchange"
        |> entries()
        |> stop_payload(session_id: "backfill-5")
        |> Map.put("user_id", "someone-else")

      post(conn, ~p"/hooks/backfill", body)

      assert 4 == length(Messages.for_run(posted_scope("backfill-5")))

      assert [] ==
               Messages.for_run(
                 Scope.new(user_id: "someone-else", app_id: "widget", run_id: "backfill-5")
               )
    end
  end

  describe "GET /hooks/lines-seen" do
    test "a run nothing was stored for has seen no lines", %{conn: conn} do
      conn =
        get(conn, ~p"/hooks/lines-seen", session_id: "seen-1", cwd: "/Users/example/Code/widget")

      assert %{"lines_seen" => 0} == json_response(conn, 200)
    end

    test "after a backfill it counts every line up to the last stored", %{conn: conn} do
      body = "plain_exchange" |> entries() |> stop_payload(session_id: "seen-2", offset: 40)

      post(conn, ~p"/hooks/backfill", body)

      conn =
        get(conn, ~p"/hooks/lines-seen", session_id: "seen-2", cwd: "/Users/example/Code/widget")

      # The slice sat at lines 40..43, so lines 0..43 are accounted for.
      assert %{"lines_seen" => 44} == json_response(conn, 200)
    end

    test "another run's messages do not raise this run's count", %{conn: conn} do
      body = "plain_exchange" |> entries() |> stop_payload(session_id: "seen-3")

      post(conn, ~p"/hooks/backfill", body)

      conn =
        get(conn, ~p"/hooks/lines-seen", session_id: "seen-4", cwd: "/Users/example/Code/widget")

      assert %{"lines_seen" => 0} == json_response(conn, 200)
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

  @doc false
  def send_refresh_event(_event, _measurements, metadata, pid),
    do: send(pid, {:refreshed, metadata.outcome})

  @doc false
  def send_pulse_event(_event, _measurements, metadata, pid),
    do: send(pid, {:pulsed, metadata.outcome})

  # An external capture rather than a local one, for `Mem0.MessagesTest`'s
  # reason: `:telemetry` warns about local-function handlers.
  defp forward_refresh_telemetry(_context) do
    handler_id = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:mem0, :summarize, :refresh],
        &__MODULE__.send_refresh_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  defp forward_pulse_telemetry(_context) do
    handler_id = {__MODULE__, :pulse, self()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:mem0, :reconcile, :pulse],
        &__MODULE__.send_pulse_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  defp start_stubs(_context) do
    LLM.Stub.start!()
    Embedder.Stub.start!()
    :ok
  end

  defp await_refresh(count) do
    for _ <- 1..count do
      assert_receive {:refreshed, outcome}, 1_000
      outcome
    end
  end

  defp await_pulse(count) do
    for _ <- 1..count do
      assert_receive {:pulsed, outcome}, 1_000
      outcome
    end
  end
end
