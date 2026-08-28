defmodule Mem0.ProcessorTest do
  @moduledoc """
  The extract-then-embed pass over one stored session, with both ports
  stubbed: facts land in the store with embeddings, and the watermark moves
  so the next pass reads nothing twice.
  """
  use Mem0.DataCase, async: true

  alias Mem0.Embedder
  alias Mem0.LLM
  alias Mem0.Processor
  alias Mem0.Store.Facts
  alias Mem0.Store.Messages
  alias Mem0.Store.Scopes

  @epoch ~U[2026-08-24 09:00:00.000000Z]

  setup do
    LLM.Stub.start!()
    Embedder.Stub.start!()

    {:ok, scope} = Scopes.create(%{user: "u", project: "/code/widget", session: "session-1"})

    for {content, seconds} <- [{"I prefer Elixir", 0}, {"Noted.", 1}] do
      {:ok, _message} =
        Messages.create(%{
          scope_id: scope.id,
          role: "user",
          content: content,
          timestamp: DateTime.add(@epoch, seconds, :second)
        })
    end

    %{scope: scope}
  end

  describe "process_session/1" do
    test "extracts, stores and embeds the session's facts", %{scope: scope} do
      set_facts_reply(["Prefers Elixir"])

      assert [:ok] = Processor.process_session("session-1")

      assert [fact] = Facts.list()
      assert fact.fact == "Prefers Elixir"
      assert fact.scope_id == scope.id
      refute fact.embedding_768 == nil

      last_id = Messages.get_session("session-1") |> List.last() |> Map.fetch!(:id)
      assert Scopes.get(scope.id).last_extracted_message_id == last_id
    end

    test "a second pass over an unchanged session extracts nothing", %{scope: scope} do
      set_facts_reply(["Prefers Elixir"])

      assert [:ok] = Processor.process_session("session-1")
      assert [] = Processor.process_session("session-1")

      assert [_only_one] = Facts.list()
      assert [_only_one_call] = LLM.Stub.calls()
      assert Scopes.get(scope.id).last_extracted_message_id != nil
    end

    test "a session nobody stored is an error" do
      assert {:error, :session_does_not_exist} = Processor.process_session("session-9")
    end

    test "an extraction failure stops the pass before embedding" do
      LLM.Stub.set({:error, {:http_error, 500, %{}}})

      assert {:error, {:http_error, 500, _body}} = Processor.process_session("session-1")
      assert Facts.list() == []
      assert Embedder.Stub.calls() == []
    end
  end

  defp set_facts_reply(facts) do
    LLM.Stub.set({:ok, LLM.Stub.response(Jason.encode!(%{"facts" => facts}))})
  end
end
