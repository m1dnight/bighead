defmodule Mem0.ExtractorTest do
  @moduledoc """
  Extraction through the stubbed LLM: what gets asked and what comes back.
  The extractor is pure over the messages it is handed — watermark and scope
  concerns live in the processor. No test here spends money.
  """
  use Mem0.DataCase, async: true

  alias Mem0.Extractor
  alias Mem0.Extractor.Prompt
  alias Mem0.LLM
  alias Mem0.Store.Facts
  alias Mem0.Store.Messages
  alias Mem0.Store.Scopes

  @epoch ~U[2026-08-24 09:00:00.000000Z]

  setup do
    LLM.Stub.start!()

    {:ok, scope} = Scopes.create(%{user: "u", project: "/code/widget", session: "session-1"})

    messages =
      for {content, seconds} <- [{"I prefer Elixir", 0}, {"Noted.", 1}] do
        {:ok, message} =
          Messages.create(%{
            scope_id: scope.id,
            role: "user",
            content: content,
            timestamp: DateTime.add(@epoch, seconds, :second)
          })

        message
      end

    %{scope: scope, messages: messages}
  end

  describe "extract_facts/2" do
    test "returns the extracted facts and neither stores nor advances anything", %{
      scope: scope,
      messages: messages
    } do
      set_facts_reply(["Prefers Elixir"])

      assert {:ok, ["Prefers Elixir"]} = Extractor.extract_facts(messages, "")

      assert Facts.list() == []
      assert Scopes.get(scope.id).last_extracted_message_id == nil
    end

    test "asks with the extraction prompt, the schema and the conversation", %{
      messages: messages
    } do
      set_facts_reply([])

      assert {:ok, []} = Extractor.extract_facts(messages, "the summary")

      assert [request] = LLM.Stub.calls()
      assert request.system == Prompt.system_prompt()
      assert request.schema["required"] == ["facts"]

      assert [%{role: :user, content: prompt}] = request.messages
      assert prompt =~ "the summary"
      assert prompt =~ "user: I prefer Elixir"
    end

    test "no messages is zero facts, not an error" do
      assert {:ok, []} = Extractor.extract_facts([], "")
      assert LLM.Stub.calls() == []
    end

    test "an LLM failure comes back as that failure", %{messages: messages} do
      LLM.Stub.set({:error, {:http_error, 429, %{"error" => "rate_limit_error"}}})

      assert {:error, {:http_error, 429, _body}} = Extractor.extract_facts(messages, "")
    end

    test "a reply that is not the schema's shape is an error", %{messages: messages} do
      LLM.Stub.set({:ok, LLM.Stub.response("not json at all")})

      assert {:error, :invalid_response_from_llm} = Extractor.extract_facts(messages, "")
    end
  end

  defp set_facts_reply(facts) do
    LLM.Stub.set({:ok, LLM.Stub.response(Jason.encode!(%{"facts" => facts}))})
  end
end
