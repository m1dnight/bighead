defmodule Mem0.SummarizeTest do
  @moduledoc """
  The one impure step: clock, port, decode.

  Everything here runs against `Mem0.LLM.Stub` except the `:live` test at the
  bottom, which is the only thing that can show the property regeneration buys
  by construction — a summary over a longer history still carrying the early
  facts.
  """
  use ExUnit.Case, async: true
  use Mem0.CoreFixtures

  alias Mem0.Core.Transcript.ClaudeCode
  alias Mem0.LLM
  alias Mem0.LLM.Anthropic
  alias Mem0.Summarize
  alias Mem0.TranscriptFixtures

  setup do
    LLM.Stub.start!()
    :ok
  end

  test "an empty history is refused without spending a call" do
    assert Summarize.regenerate([]) == {:error, :no_messages}
    assert LLM.Stub.calls() == []
  end

  test "a reply becomes the summary, in the batch's scope, freshly stamped" do
    LLM.Stub.set({:ok, LLM.Stub.response(~s({"summary": "The user uses Elixir."}))})
    scope = scope(app_id: "widget")
    before = DateTime.utc_now()

    assert {:ok, %Summary{} = summary} = Summarize.regenerate([message(scope: scope)])
    assert summary.scope == scope
    assert summary.text == "The user uses Elixir."
    assert DateTime.compare(summary.generated_at, before) != :lt
  end

  test "the watermark is the highest seq, however the list is ordered" do
    LLM.Stub.set({:ok, LLM.Stub.response(~s({"summary": "The user uses Elixir."}))})

    messages = [
      message(id: "m-7", seq: 7),
      message(id: "m-9", seq: 9),
      message(id: "m-8", seq: 8)
    ]

    assert {:ok, summary} = Summarize.regenerate(messages)
    assert summary.through_seq == 9
  end

  test "sends the system prompt, the schema and the rendered history" do
    Summarize.regenerate([message(content: "I use Elixir.")])

    assert [request] = LLM.Stub.calls()
    assert request.system == Summary.system_prompt()
    assert request.schema["required"] == ["summary"]
    assert request.messages == [%{role: :user, content: "user: I use Elixir."}]
  end

  test "opts reach the port, so one call can override the model" do
    LLM.Stub.set(fn _request, opts ->
      {:ok, LLM.Stub.response(~s({"summary": #{inspect(opts[:model])}}))}
    end)

    assert {:ok, summary} = Summarize.regenerate([message()], model: "claude-opus-5")
    assert summary.text == "claude-opus-5"
  end

  for reason <- [
        {:refusal, "cyber"},
        {:http_error, 429, %{"error" => "rate_limit_error"}},
        {:transport_error, %Req.TransportError{reason: :timeout}}
      ] do
    test "#{inspect(reason)} from the port passes through unchanged" do
      LLM.Stub.set({:error, unquote(Macro.escape(reason))})

      assert Summarize.regenerate([message()]) == {:error, unquote(Macro.escape(reason))}
    end
  end

  test "a reply that is not the agreed shape is malformed, not a crash" do
    LLM.Stub.set({:ok, LLM.Stub.response("Sure! Here's what happened so far:")})

    assert Summarize.regenerate([message()]) == {:error, :malformed_summary}
  end

  # The one test that can fail for a reason worth knowing: the prompt. It
  # asserts shape only, because "is this a good summary" is not an assertion —
  # run it by hand with `mix test.live` and read what it prints. The property
  # to read for: the second summary is regenerated over the whole history, so
  # the early facts (the tabs preference) must still be in it.
  @tag :live
  test "a regeneration over a longer history still carries the early facts" do
    config = Application.fetch_env!(:mem0, :live_llm)

    assert config[:api_key], "ANTHROPIC_API_KEY is not set; mix test.live needs it"

    scope = scope()

    {messages, _drops} =
      ClaudeCode.messages(TranscriptFixtures.entries("plain_exchange"), scope, 0)

    half = Enum.take(messages, div(length(messages), 2))

    assert {:ok, first} = regenerate_live(half, scope, config)
    assert {:ok, second} = regenerate_live(messages, scope, config)
    assert second.through_seq >= first.through_seq

    IO.puts("\n--- summary over the first half ---\n" <> first.text)
    IO.puts("\n--- summary over the whole session ---\n" <> second.text)
  end

  # `Summarize.regenerate/2` itself would go through the configured adapter —
  # the stub, under test — so the live test does what the boundary does with
  # the same pure halves: the request and decode are the same bytes.
  defp regenerate_live(messages, scope, config) do
    %Message{seq: through_seq} = Enum.max_by(messages, & &1.seq)

    with {:ok, response} <- Anthropic.complete(Summary.request(messages), config) do
      Summary.decode(response.content, scope, at(0), through_seq)
    end
  end
end
