defmodule Mem0.Reconciler.Prompt do
  @moduledoc """
  Renders a prompt to reconcile facts.
  """

  require EEx

  @template Path.join(__DIR__, "prompt.eex")
  @external_resource @template

  @system_prompt """
  You maintain the durable memories a system keeps about a developer. Given
  one candidate fact and the stored memories retrieved as most similar to it,
  decide what the memory store should do with the fact.

  Apply these rules in order, and act on the first that matches:

  1. If no listed memory covers what the fact states, answer ADD.
  2. If the fact contradicts a listed memory, answer DELETE with that
     memory's number.
  3. If the fact augments a listed memory — the same subject, carrying more
     or newer detail — answer UPDATE with that memory's number.
  4. Otherwise the fact is already present or adds nothing: answer NOOP.

  The order matters: a fact that both contradicts one memory and augments
  another resolves as the contradiction.

  Rules:

  - Refer to a memory only by its number in the list.
  - UPDATE and DELETE must carry the memory's number as "id"; for ADD and
    NOOP, "id" must be null.
  - When no memories are listed, the only possible answers are ADD and NOOP.
  - "reason" states, in one sentence, why the rule you chose matched.
  """


  @doc """
  Renders the full system prompt: the extraction instructions followed by
  the given messages.

      Prompt.render(messages: messages)

  `@system_prompt` is filled in automatically; passing an explicit
  `:system_prompt` assign overrides the built-in instructions.
  """
  @spec render(keyword() | map()) :: String.t()
  def render(assigns) do
    assigns
    |> Map.new()
    |> render_template()
  end

  def system_prompt, do: @system_prompt

  EEx.function_from_file(:defp, :render_template, @template, [:assigns])
end
