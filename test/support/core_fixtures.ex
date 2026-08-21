defmodule Mem0.CoreFixtures do
  @moduledoc """
  Plain-function fixtures for the functional core.

  Every noun gets a `*_fields/1` returning a keyword list with sensible defaults
  merged under the caller's `overrides`, and a builder that runs those fields
  through the real `new/1`. The builders read each field back with
  `Keyword.fetch!/2` on purpose: a field dropped from the defaults raises at the
  fixture rather than producing a subtly wrong struct three tests away.

  Time is a fixture too. The core never reads a clock, so tests never need one —
  `at/1` returns a deterministic instant a given number of seconds after a fixed
  epoch, and every timestamp in this file comes from it.

  `use Mem0.CoreFixtures` imports these and aliases the core modules, so a test
  file opens with one line.
  """

  alias Mem0.Core.Decision
  alias Mem0.Core.Extraction
  alias Mem0.Core.Fact
  alias Mem0.Core.Memory
  alias Mem0.Core.Message
  alias Mem0.Core.Prompt
  alias Mem0.Core.Scope
  alias Mem0.Core.Summary

  @epoch ~U[2026-01-01 00:00:00.000000Z]

  defmacro __using__(_opts) do
    quote do
      import Mem0.CoreFixtures

      alias Mem0.Core.Decision
      alias Mem0.Core.Extraction
      alias Mem0.Core.Fact
      alias Mem0.Core.Memory
      alias Mem0.Core.MemoryOperation
      alias Mem0.Core.Message
      alias Mem0.Core.Prompt
      alias Mem0.Core.Scope
      alias Mem0.Core.ScopeQuery
      alias Mem0.Core.Scored
      alias Mem0.Core.Summary
    end
  end

  @doc "A deterministic instant, `seconds` after a fixed epoch."
  @spec at(integer()) :: DateTime.t()
  def at(seconds \\ 0), do: DateTime.add(@epoch, seconds, :second)

  def scope_fields(overrides \\ []) do
    Keyword.merge([user_id: "christophe", app_id: "mem0", run_id: "session-1"], overrides)
  end

  def scope(overrides \\ []) do
    fields = scope_fields(overrides)

    Scope.new(
      user_id: Keyword.fetch!(fields, :user_id),
      app_id: Keyword.fetch!(fields, :app_id),
      run_id: Keyword.fetch!(fields, :run_id)
    )
  end

  def message_fields(overrides \\ []) do
    Keyword.merge(
      [
        id: "msg-1",
        scope: scope(),
        role: :user,
        content: "I live in San Francisco.",
        said_at: at(0),
        seq: 1
      ],
      overrides
    )
  end

  def message(overrides \\ []) do
    fields = message_fields(overrides)

    Message.new(
      id: Keyword.fetch!(fields, :id),
      scope: Keyword.fetch!(fields, :scope),
      role: Keyword.fetch!(fields, :role),
      content: Keyword.fetch!(fields, :content),
      said_at: Keyword.fetch!(fields, :said_at),
      seq: Keyword.fetch!(fields, :seq)
    )
  end

  def summary_fields(overrides \\ []) do
    Keyword.merge(
      [
        scope: scope(),
        text: "The user talked about where they live.",
        generated_at: at(0),
        through_seq: 4
      ],
      overrides
    )
  end

  def summary(overrides \\ []) do
    fields = summary_fields(overrides)

    Summary.new(
      scope: Keyword.fetch!(fields, :scope),
      text: Keyword.fetch!(fields, :text),
      generated_at: Keyword.fetch!(fields, :generated_at),
      through_seq: Keyword.fetch!(fields, :through_seq)
    )
  end

  def prompt_fields(overrides \\ []) do
    Keyword.merge(
      [
        scope: scope(),
        summary: summary(),
        recent: [message(id: "msg-1", seq: 1)],
        pair: {message(id: "msg-2", seq: 2), message(id: "msg-3", role: :assistant, seq: 3)},
        at: at(10)
      ],
      overrides
    )
  end

  def prompt(overrides \\ []) do
    fields = prompt_fields(overrides)

    Prompt.new(
      scope: Keyword.fetch!(fields, :scope),
      summary: Keyword.fetch!(fields, :summary),
      recent: Keyword.fetch!(fields, :recent),
      pair: Keyword.fetch!(fields, :pair),
      at: Keyword.fetch!(fields, :at)
    )
  end

  def fact_fields(overrides \\ []) do
    Keyword.merge(
      [
        content: "User lives in San Francisco",
        scope: scope(),
        extracted_at: at(10),
        event_time: nil,
        source_message_ids: ["msg-2", "msg-3"]
      ],
      overrides
    )
  end

  def fact(overrides \\ []) do
    fields = fact_fields(overrides)

    Fact.new(
      content: Keyword.fetch!(fields, :content),
      scope: Keyword.fetch!(fields, :scope),
      extracted_at: Keyword.fetch!(fields, :extracted_at),
      event_time: Keyword.fetch!(fields, :event_time),
      source_message_ids: Keyword.fetch!(fields, :source_message_ids)
    )
  end

  def extraction_fields(overrides \\ []) do
    Keyword.merge(
      [
        scope: scope(),
        prompt_at: at(10),
        facts: [fact()],
        source_message_ids: ["msg-2", "msg-3"]
      ],
      overrides
    )
  end

  def extraction(overrides \\ []) do
    fields = extraction_fields(overrides)

    Extraction.new(
      scope: Keyword.fetch!(fields, :scope),
      prompt_at: Keyword.fetch!(fields, :prompt_at),
      facts: Keyword.fetch!(fields, :facts),
      source_message_ids: Keyword.fetch!(fields, :source_message_ids)
    )
  end

  def memory_fields(overrides \\ []) do
    Keyword.merge(
      [
        id: "mem-1",
        scope: scope(),
        content: "User lives in San Francisco",
        extracted_at: at(10),
        event_time: nil,
        source_message_ids: ["msg-2", "msg-3"],
        created_at: at(10),
        updated_at: at(10)
      ],
      overrides
    )
  end

  def memory(overrides \\ []) do
    fields = memory_fields(overrides)

    Memory.new(
      id: Keyword.fetch!(fields, :id),
      scope: Keyword.fetch!(fields, :scope),
      content: Keyword.fetch!(fields, :content),
      extracted_at: Keyword.fetch!(fields, :extracted_at),
      event_time: Keyword.fetch!(fields, :event_time),
      source_message_ids: Keyword.fetch!(fields, :source_message_ids),
      created_at: Keyword.fetch!(fields, :created_at),
      updated_at: Keyword.fetch!(fields, :updated_at)
    )
  end

  def decision_fields(overrides \\ []) do
    Keyword.merge(
      [
        operation: {:add, fact()},
        reason: "Nothing retrieved said anything about where the user lives.",
        considered_ids: ["mem-1"],
        decided_at: at(11)
      ],
      overrides
    )
  end

  def decision(overrides \\ []) do
    fields = decision_fields(overrides)

    Decision.new(
      operation: Keyword.fetch!(fields, :operation),
      reason: Keyword.fetch!(fields, :reason),
      considered_ids: Keyword.fetch!(fields, :considered_ids),
      decided_at: Keyword.fetch!(fields, :decided_at)
    )
  end
end
