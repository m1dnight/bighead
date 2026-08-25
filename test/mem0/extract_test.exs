defmodule Mem0.ExtractTest do
  @moduledoc """
  The one impure step: clock, port, decode.

  Everything here runs against `Mem0.LLM.Stub` except the `:live` test at the
  bottom, which is the only thing that can tell you whether the prompt is any
  good. `facts_since/3` — the composition over the stores — is
  `Mem0.ExtractSinceTest`'s job, for `Mem0.SummarizeRefreshTest`'s reason: it
  is the first extraction suite that needs a database.
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

  test "a prompt with nothing new is refused without spending a call" do
    assert Extract.facts(prompt(new: [])) == {:error, :no_messages}
    assert LLM.Stub.calls() == []
  end

  test "a reply becomes facts, in the prompt's scope" do
    LLM.Stub.set({:ok, LLM.Stub.response(~s({"facts": ["Uses Elixir"]}))})
    scope = scope(app_id: "widget")

    assert {:ok, extraction} = Extract.facts(prompt(scope: scope, new: [message(scope: scope)]))
    assert extraction.scope == scope
    assert [%Fact{content: "Uses Elixir", scope: ^scope}] = extraction.facts
  end

  test "stamps the extraction and its facts with the same instant" do
    LLM.Stub.set({:ok, LLM.Stub.response(~s({"facts": ["Uses Elixir"]}))})
    before = DateTime.utc_now()

    assert {:ok, extraction} = Extract.facts(prompt())
    assert [fact] = extraction.facts
    assert fact.extracted_at == extraction.prompt_at
    assert DateTime.compare(extraction.prompt_at, before) != :lt
  end

  test "provenance names the new slice's ids only, even with context present" do
    LLM.Stub.set({:ok, LLM.Stub.response(~s({"facts": ["Uses Elixir"]}))})

    prompt =
      prompt(
        summary: summary(),
        recent: [message(id: "m-1", seq: 1)],
        new: [message(id: "m-2", seq: 2), message(id: "m-3", role: :assistant, seq: 3)]
      )

    assert {:ok, extraction} = Extract.facts(prompt)
    assert extraction.source_message_ids == ["m-2", "m-3"]
    assert [%Fact{source_message_ids: ["m-2", "m-3"]}] = extraction.facts
  end

  test "sends the system prompt, the schema and the sectioned prompt" do
    prompt =
      prompt(
        summary: summary(text: "The user uses Elixir."),
        recent: [message(id: "m-1", content: "Earlier remark.", seq: 1)],
        new: [message(id: "m-2", content: "I use tabs.", seq: 2)]
      )

    Extract.facts(prompt)

    assert [request] = LLM.Stub.calls()
    assert request.system == Extraction.system_prompt()
    assert request.schema["required"] == ["facts"]
    assert [%{role: :user, content: content}] = request.messages
    assert content == Extraction.render(prompt)
    assert content =~ "# Conversation summary\nThe user uses Elixir."
    assert content =~ "# Earlier messages (context)\nuser: Earlier remark."
    assert content =~ "# New messages (extract from these only)\nuser: I use tabs."
  end

  test "opts reach the port, so one call can override the model" do
    LLM.Stub.set(fn _request, opts ->
      {:ok, LLM.Stub.response(~s({"facts": [#{inspect(opts[:model])}]}))}
    end)

    assert {:ok, extraction} = Extract.facts(prompt(), model: "claude-opus-5")
    assert [%Fact{content: "claude-opus-5"}] = extraction.facts
  end

  for reason <- [
        {:refusal, "cyber"},
        {:http_error, 429, %{"error" => "rate_limit_error"}},
        {:transport_error, %Req.TransportError{reason: :timeout}}
      ] do
    test "#{inspect(reason)} from the port passes through unchanged" do
      LLM.Stub.set({:error, unquote(Macro.escape(reason))})

      assert Extract.facts(prompt()) == {:error, unquote(Macro.escape(reason))}
    end
  end

  test "a reply that is not the agreed shape is malformed, not a crash" do
    LLM.Stub.set({:ok, LLM.Stub.response("Sure! Here are the facts I found:")})

    assert Extract.facts(prompt()) == {:error, :malformed_facts}
  end

  # The one test that can fail for a reason worth knowing: the prompt. It
  # asserts almost nothing, because "are these good facts" is not an assertion
  # — run it by hand with `mix test.live` and read what it prints. The property
  # to read for: the second run's facts come only from the tail, and
  # references the tail cannot resolve alone arrive resolved.
  @tag :live
  test "the tail extracted with a real summary arrives with references resolved" do
    config = Application.fetch_env!(:mem0, :live_llm)

    assert config[:api_key], "ANTHROPIC_API_KEY is not set; mix test.live needs it"

    scope = scope()

    {messages, _drops} =
      ClaudeCode.messages(TranscriptFixtures.entries("plain_exchange"), scope, 0)

    # The whole conversation, no watermark, no summary — the Phase 5 shape.
    assert {:ok, whole} = extract_live(messages, nil, nil, config)

    # The tail only, with the summary a real regeneration produced over the head.
    head = Enum.take(messages, div(length(messages), 2))
    %Message{seq: last_message_seq} = Enum.max_by(head, & &1.seq)
    assert {:ok, summary} = summarize_live(head, scope, config)
    assert {:ok, tail} = extract_live(messages, last_message_seq, summary, config)

    assert Enum.all?(tail.source_message_ids, fn id ->
             id not in Enum.map(head, & &1.id)
           end)

    IO.puts("\n--- facts, whole conversation, no summary ---")
    Enum.each(whole.facts, &IO.puts("  • " <> &1.content))
    IO.puts("\n--- facts, tail only, informed by the summary ---")
    Enum.each(tail.facts, &IO.puts("  • " <> &1.content))
  end

  # `Extract.facts/2` itself would go through the configured adapter — the
  # stub, under test — so the live test does what the boundary does with the
  # same pure halves: the request and decode are the same bytes.
  defp extract_live(messages, last_message_seq, summary, config) do
    {:ok, prompt} =
      Prompt.from_history(
        messages: messages,
        last_message_seq: last_message_seq,
        summary: summary
      )

    with {:ok, response} <- Anthropic.complete(Extraction.request(prompt), config) do
      Extraction.decode(response.content, prompt.scope, at(0), Enum.map(prompt.new, & &1.id))
    end
  end

  defp summarize_live(messages, scope, config) do
    %Message{seq: through_seq} = Enum.max_by(messages, & &1.seq)

    with {:ok, response} <- Anthropic.complete(Summary.request(messages), config) do
      Summary.decode(response.content, scope, at(0), through_seq)
    end
  end
end
