defmodule Mem0Web.TranscriptControllerTest do
  @moduledoc """
  The raw-file cousin of `backfill` plus a synchronous pulse, so unlike the
  hook suites most of what is under test here answers honestly rather than
  always-200. The refresh still runs on a task, so these drain its telemetry
  like the stop tests do; the pulse itself runs in the request and reports
  through the response.

  `async: false` for the refresh task's shared sandbox connection, as in
  `Mem0Web.HooksControllerTest`.
  """

  use Mem0Web.ConnCase, async: false
  use Mem0.CoreFixtures

  import Mem0.TranscriptFixtures, only: [entries: 1]

  alias Mem0.Embedder
  alias Mem0.ExtractionState
  alias Mem0.Ingest
  alias Mem0.LLM
  alias Mem0.Memories
  alias Mem0.Messages

  setup [:forward_refresh_telemetry, :start_stubs]

  describe "POST /transcripts" do
    test "a posted file lands messages, a memory, and the cursor in one request", %{conn: conn} do
      LLM.Stub.set(fn request, _opts ->
        if request.system == Extraction.system_prompt() do
          {:ok, LLM.Stub.response(~s({"facts": ["User prefers tabs over spaces"]}))}
        else
          {:ok, LLM.Stub.response(~s({"event": "ADD", "reason": "Nothing covers this."}))}
        end
      end)

      response =
        conn
        |> put_req_header("content-type", "application/jsonl")
        |> post(~p"/transcripts", jsonl("plain_exchange"))
        |> json_response(200)

      assert response == %{
               "stored" => 4,
               "dropped" => 0,
               "pulse" => %{
                 "outcome" => "reconciled",
                 "facts" => 1,
                 "operations" => %{"add" => 1}
               }
             }

      # The scope came from the file's own sessionId and cwd; the file's four
      # lines sit at seqs 0..3, so the cursor rests on 3.
      assert length(Messages.for_run(file_scope())) == 4
      assert ExtractionState.through_seq(file_scope()) == 3

      assert [%Memory{content: "User prefers tabs over spaces"}] =
               Memories.active(ScopeQuery.new(user_id: Ingest.default_user_id()))

      await_refresh(1)
    end

    test "posting the same file twice stores nothing new and pulses nothing", %{conn: conn} do
      LLM.Stub.set({:ok, LLM.Stub.response(~s({"facts": []}))})

      post_file = fn ->
        conn
        |> put_req_header("content-type", "application/jsonl")
        |> post(~p"/transcripts", jsonl("plain_exchange"))
        |> json_response(200)
      end

      assert %{"stored" => 4, "pulse" => %{"outcome" => "reconciled", "facts" => 0}} =
               post_file.()

      assert %{"stored" => 0, "pulse" => %{"outcome" => "nothing_new"}} = post_file.()

      await_refresh(2)
    end

    test "session_id and cwd query params override the file's own", %{conn: conn} do
      LLM.Stub.set({:ok, LLM.Stub.response(~s({"facts": []}))})

      response =
        conn
        |> put_req_header("content-type", "application/jsonl")
        |> post(
          ~p"/transcripts?session_id=override-run&cwd=/tmp/other-app",
          jsonl("plain_exchange")
        )
        |> json_response(200)

      assert response["stored"] == 4

      scope =
        Scope.new(
          user_id: Ingest.default_user_id(),
          app_id: "other-app",
          run_id: "override-run"
        )

      assert length(Messages.for_run(scope)) == 4
      assert Messages.for_run(file_scope()) == []
      await_refresh(1)
    end

    test "a line that is not JSON is a 422 naming the line, and nothing runs", %{conn: conn} do
      body = ~s({"type": "summary"}\nnot json at all\n)

      response =
        conn
        |> put_req_header("content-type", "application/jsonl")
        |> post(~p"/transcripts", body)
        |> json_response(422)

      assert response["error"] == "line 2 is not JSON"

      # Decoding failed before ingest: no refresh task, no pulse, no LLM call.
      refute_receive {:refreshed, _outcome}, 100
      assert LLM.Stub.calls() == []
    end
  end

  # The scope plain_exchange.jsonl's own sessionId and cwd land on.
  defp file_scope do
    Scope.new(
      user_id: Ingest.default_user_id(),
      app_id: "widget",
      run_id: "11111111-1111-4111-8111-111111111111"
    )
  end

  defp jsonl(name), do: name |> entries() |> Enum.map_join("\n", &Jason.encode!/1)

  @doc false
  def send_refresh_event(_event, _measurements, metadata, pid),
    do: send(pid, {:refreshed, metadata.outcome})

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
end
