defmodule Mem0.ExtractTest do
  @moduledoc """
  The one impure step: clock, port, decode.

  Everything here runs against `Mem0.LLM.Stub` except the `:live` test at the
  bottom, which is the only thing that can tell you whether the prompt is any
  good.
  """
  use ExUnit.Case, async: true
  use Mem0.CoreFixtures

  alias Mem0.Core.Transcript.ClaudeCode
  alias Mem0.Extract
  alias Mem0.LLM
  alias Mem0.LLM.Anthropic
  alias Mem0.TranscriptFixtures

  setup do
    LLM.Stub.start!()
    :ok
  end

  test "an empty batch is refused without spending a call" do
    assert Extract.facts([]) == {:error, :no_messages}
    assert LLM.Stub.calls() == []
  end

  test "a reply becomes facts, in the batch's scope" do
    LLM.Stub.set({:ok, LLM.Stub.response(~s({"facts": ["Uses Elixir"]}))})
    scope = scope(app_id: "widget")

    assert {:ok, extraction} = Extract.facts([message(scope: scope, content: "I use Elixir.")])
    assert extraction.scope == scope
    assert [%Fact{content: "Uses Elixir", scope: ^scope}] = extraction.facts
  end

  test "stamps the extraction and its facts with the same instant" do
    LLM.Stub.set({:ok, LLM.Stub.response(~s({"facts": ["Uses Elixir"]}))})
    before = DateTime.utc_now()

    assert {:ok, extraction} = Extract.facts([message()])
    assert [fact] = extraction.facts
    assert fact.extracted_at == extraction.prompt_at
    assert DateTime.compare(extraction.prompt_at, before) != :lt
  end

  test "every message in the batch is the source of every fact" do
    LLM.Stub.set({:ok, LLM.Stub.response(~s({"facts": ["Uses Elixir"]}))})

    messages = [message(id: "m-1", seq: 1), message(id: "m-2", role: :assistant, seq: 2)]

    assert {:ok, extraction} = Extract.facts(messages)
    assert extraction.source_message_ids == ["m-1", "m-2"]
    assert [%Fact{source_message_ids: ["m-1", "m-2"]}] = extraction.facts
  end

  test "sends the system prompt, the schema and the rendered transcript" do
    Extract.facts([message(content: "I use Elixir.")])

    assert [request] = LLM.Stub.calls()
    assert request.system == Extraction.system_prompt()
    assert request.schema["required"] == ["facts"]
    assert request.messages == [%{role: :user, content: "user: I use Elixir."}]
  end

  test "opts reach the port, so one call can override the model" do
    LLM.Stub.set(fn _request, opts ->
      {:ok, LLM.Stub.response(~s({"facts": [#{inspect(opts[:model])}]}))}
    end)

    assert {:ok, extraction} = Extract.facts([message()], model: "claude-opus-5")
    assert [%Fact{content: "claude-opus-5"}] = extraction.facts
  end

  for reason <- [
        {:refusal, "cyber"},
        {:http_error, 429, %{"error" => "rate_limit_error"}},
        {:transport_error, %Req.TransportError{reason: :timeout}}
      ] do
    test "#{inspect(reason)} from the port passes through unchanged" do
      LLM.Stub.set({:error, unquote(Macro.escape(reason))})

      assert Extract.facts([message()]) == {:error, unquote(Macro.escape(reason))}
    end
  end

  test "a reply that is not the agreed shape is malformed, not a crash" do
    LLM.Stub.set({:ok, LLM.Stub.response("Sure! Here are the facts I found:")})

    assert Extract.facts([message()]) == {:error, :malformed_facts}
  end

  # The one test that can fail for a reason worth knowing: the prompt. It asserts
  # almost nothing, because "are these good facts" is not an assertion — run it
  # by hand with `mix test.live` and read what it prints.
  @tag :live
  test "the real prompt, against a real model and a real transcript" do
    config = Application.fetch_env!(:mem0, :live_llm)

    assert config[:api_key], "ANTHROPIC_API_KEY is not set; mix test.live needs it"

    scope = scope()

    {messages, _drops} =
      ClaudeCode.messages(TranscriptFixtures.entries("plain_exchange"), scope, 0)

    assert {:ok, response} = Anthropic.complete(Extraction.request(messages), config)

    assert {:ok, extraction} =
             Extraction.decode(response.content, scope, at(0), Enum.map(messages, & &1.id))

    IO.puts("\n--- facts from plain_exchange ---")
    Enum.each(extraction.facts, &IO.puts("  • " <> &1.content))
  end
end
