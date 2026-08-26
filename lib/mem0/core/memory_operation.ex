defmodule Mem0.Core.MemoryOperation do
  @moduledoc """
  A memory operation is what the update phase decided to do with a given fact:
  the ADD/UPDATE/DELETE/NOOP cascade of Algorithm 1 (notes §2.2, §2.3).

  `{:update, id, fact}` reads exactly as the algorithm specifies — the id
  survives, the content is replaced. Both `UPDATE` and `DELETE` carry an id
  because the algorithm resolves each against a *specific* one of the `s`
  retrieved candidates, not against the store at large.

  This module holds both halves of the conversation: `request/2` asks the
  question, `parse/4` and `decode/4` read the answer. Request and parse are
  two halves of one protocol, and splitting them invites drift.

  ## Ids are never shown to the model

  `request/2` presents the `s` retrieved candidates as `1..s`, contents only,
  and the model answers with an ordinal. `parse/4` maps that ordinal back to
  an id, given the ordered list the boundary retrieved. The mapping is a pure
  list lookup, so it stays in the core; the boundary supplies the list and
  performs the result.

  ## Reading model output is the one place the core distrusts its input

  `parse/4` returns `{:ok, t()} | {:error, term()}` and never raises. An ordinal
  outside `1..s`, a missing key, an unrecognised operation name are all
  *expected* values coming back from a language model, not programmer errors, so
  the "the core trusts its input" rule does not reach here. It is also the only
  place in this phase that turns model output into an atom, and that is safe
  because the set is closed and matched literally — never through
  `String.to_atom/1`.
  """

  alias Mem0.Core.Decision
  alias Mem0.Core.Fact
  alias Mem0.Core.Memory

  # Algorithm 1's cascade, stated *in its order* — the notes' §2.3 warning:
  # contradiction is checked before augmentation, so a fact that both
  # contradicts one memory and augments another resolves as the contradiction.
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
  - UPDATE and DELETE must carry "id"; ADD and NOOP must not.
  - When no memories are listed, the only possible answers are ADD and NOOP.
  - "reason" states, in one sentence, why the rule you chose matched.
  """

  # The reply shape `decode/4` expects, stated to the provider rather than
  # begged for in prose. The schema cannot express "id required when
  # UPDATE/DELETE" — the prose above carries that, and `parse/4` returns
  # `:missing_ordinal` when a model ignores it.
  @response_schema %{
    "additionalProperties" => false,
    "properties" => %{
      "event" => %{"enum" => ["ADD", "UPDATE", "DELETE", "NOOP"], "type" => "string"},
      "id" => %{"minimum" => 1, "type" => "integer"},
      "reason" => %{"type" => "string"}
    },
    "required" => ["event", "reason"],
    "type" => "object"
  }

  @type t ::
          {:add, Fact.t()}
          | {:update, Memory.id(), Fact.t()}
          | {:delete, Memory.id()}
          | :noop

  @typedoc """
  The `InformationContent(f) > InformationContent(m_i)` guard of Algorithm 1,
  injected. See `richer?/2` for why it is a parameter rather than a definition.
  """
  @type richer :: (Fact.t(), Memory.t() -> boolean())

  @typedoc """
  The closed set of operations a model is allowed to name, after `sanitize/1`
  has folded the spellings it arrives in — `"NONE"` and `"NOOP"` are the same
  decision — onto one atom each.
  """
  @type event :: :add | :update | :delete | :noop

  @typedoc """
  Model output once `sanitize/1` has vouched for it: a known event, and for the
  two events that resolve against a candidate, a 1-based ordinal into the list
  the model was shown. The ordinal is known to be positive but not yet known to
  be in range — that needs the list, which sanitising does not take.
  """
  @type verdict :: %{required(:event) => event(), optional(:id) => pos_integer()}

  @typedoc """
  Everything reading model output can go wrong in. All six are *expected* values
  coming back from a language model rather than programmer errors, which is why
  they are returned rather than raised.

  The two that carry a `term()` carry it verbatim, before sanitising: a log line
  reading `{:unknown_event, "merge"}` is worth more than one reading
  `{:unknown_event, :invalid}`.
  """
  @type reason ::
          :missing_event
          | :missing_ordinal
          | {:unknown_event, term()}
          | {:malformed_ordinal, term()}
          | {:ordinal_out_of_range, integer()}
          | {:malformed_output, term()}

  @doc """
  The instructions the model is given.

  Public because it is the thing most worth diffing between iterations, and
  because a test asserting it was sent should not have to restate it.
  """
  @spec system_prompt() :: String.t()
  def system_prompt, do: @system_prompt

  @doc """
  The completion request that resolves `fact` against `candidates`.

  One place builds it, so the live test and the boundary send the same bytes.
  The candidates are rendered as ordinals `1..s`, contents only — the
  module-doc promise that ids never reach the model, enforced by construction.
  """
  @spec request(Fact.t(), [Memory.t()]) :: Mem0.LLM.request()
  def request(%Fact{} = fact, candidates) when is_list(candidates) do
    %{
      messages: [%{role: :user, content: render(fact, candidates)}],
      schema: @response_schema,
      system: @system_prompt
    }
  end

  @doc """
  Renders `fact` and `candidates` as the sectioned user content the model
  reads.

  An empty candidate list renders as an explicitly empty section rather than
  no section: the model must see that nothing was retrieved, not wonder
  whether the list was cut off.

  ## Examples

      iex> fact = Mem0.Core.Fact.new(
      ...>   content: "User lives in San Francisco",
      ...>   scope: Mem0.Core.Scope.new(user_id: "christophe"),
      ...>   extracted_at: ~U[2026-01-01 00:00:00Z]
      ...> )
      iex> MemoryOperation.render(fact, [])
      "# Candidate fact\\nUser lives in San Francisco\\n\\n# Retrieved memories\\n(none)"

  """
  @spec render(Fact.t(), [Memory.t()]) :: String.t()
  def render(%Fact{} = fact, candidates) when is_list(candidates) do
    "# Candidate fact\n" <> fact.content <> "\n\n# Retrieved memories\n" <> numbered(candidates)
  end

  @doc """
  Turns the model's `reply` into a `Mem0.Core.Decision`: `Jason.decode/1`,
  then `parse/4`, then the wrap into the struct the boundary performs.

  `considered_ids` is the candidates' ids in presentation order; `reason` is
  the model's, stored verbatim — it is why `Decision` exists; `decided_at` is
  the pulse instant, passed in — the core still reads no clock. An empty
  candidate list is legal and expected: the model saw no numbered memories,
  and `parse/4` already guarantees the only in-range answers are ADD and NOOP
  because any ordinal is out of range against `[]`.
  """
  @spec decode(String.t(), Fact.t(), [Memory.t()], DateTime.t()) ::
          {:ok, Decision.t()} | {:error, reason()}
  def decode(reply, %Fact{} = fact, candidates, %DateTime{} = decided_at)
      when is_list(candidates) do
    case Jason.decode(reply) do
      {:ok, verdict} -> decision(verdict, fact, candidates, decided_at)
      {:error, _undecodable} -> {:error, {:malformed_output, reply}}
    end
  end

  defp decision(verdict, fact, candidates, decided_at) do
    with {:ok, operation} <- parse(verdict, fact, candidates) do
      {:ok,
       Decision.new(
         operation: operation,
         reason: reason(verdict),
         considered_ids: Enum.map(candidates, & &1.id),
         decided_at: decided_at
       )}
    end
  end

  # Verbatim, before `sanitize/1` folds its casing. A reply the schema should
  # have forced a reason onto but did not still decodes — a missing
  # explanation is not worth killing a parseable verdict over.
  defp reason(%{"reason" => reason}) when is_binary(reason), do: reason
  defp reason(_verdict), do: ""

  defp numbered([]), do: "(none)"

  defp numbered(candidates) do
    candidates
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {memory, ordinal} -> "#{ordinal}. #{memory.content}" end)
  end

  @doc """
  Takes in the output of an update call to the LLM and parses its result.

  The LLM will return structured JSON that defines which operation to apply to
  which facts.


  ```json
  %{"event" => "ADD"}
  %{"event" => "UPDATE", "id" => 2}
  %{"event" => "DELETE", "id" => 1}
  %{"event" => "NONE"}
  %{"event" => "NOOP"}
  ```
  """
  @spec parse(term(), Fact.t(), [Memory.t()], richer()) :: {:ok, t()} | {:error, reason()}
  def parse(model_output, fact, candidates, richer? \\ &richer?/2)

  def parse(model_output, %Fact{} = fact, candidates, richer?)
      when is_map(model_output) and is_list(candidates) do
    with {:ok, event} <- sanitize(model_output),
         {:ok, operation} <- build(event, fact, candidates) do
      {:ok, enforce_information_gain(operation, candidates, richer?)}
    end
  end

  def parse(model_output, %Fact{}, _candidates, _richer?) do
    {:error, {:malformed_output, model_output}}
  end

  # ---------------------------------------------------------------------------#
  #                                Build Operation                             #
  # ---------------------------------------------------------------------------#

  @spec build(verdict(), Fact.t(), [Memory.t()]) ::
          {:ok, t()} | {:error, {:ordinal_out_of_range, pos_integer()}}
  defp build(event, fact, candidates) do
    case event do
      %{event: :add} ->
        {:ok, {:add, fact}}

      %{event: :noop} ->
        {:ok, :noop}

      %{event: :update, id: id} ->
        with {:ok, memory} <- fetch_candidate(id, candidates) do
          {:ok, {:update, memory.id, fact}}
        end

      %{event: :delete, id: id} ->
        with {:ok, memory} <- fetch_candidate(id, candidates) do
          {:ok, {:delete, memory.id}}
        end
    end
  end

  @spec fetch_candidate(pos_integer(), [Memory.t()]) ::
          {:ok, Memory.t()} | {:error, {:ordinal_out_of_range, pos_integer()}}
  defp fetch_candidate(id, candidates) do
    case Enum.at(candidates, id - 1) do
      %Memory{} = memory ->
        {:ok, memory}

      nil ->
        {:error, {:ordinal_out_of_range, id}}
    end
  end

  # ---------------------------------------------------------------------------#
  #                                Sanitize Model Output                       #
  # ---------------------------------------------------------------------------#

  defguard is_valid_id(value) when is_integer(value) and value >= 1

  @doc """
  Converts the json output coming from the model into a sanitized map.

  Event names are matched case-insensitively and the spellings a model reaches
  for are folded onto the closed set of `t:event/0` atoms — `"NONE"` and
  `"NOOP"` are the same decision. Ordinals arrive as integers or as digit
  strings and come out as integers either way. Both are things models do.

  The atoms are safe: the set is closed and matched literally, never built with
  `String.to_atom/1`.
  """
  @spec sanitize(term()) :: {:ok, verdict()} | {:error, reason()}
  def sanitize(model_output) when is_map(model_output) do
    model_output
    |> Map.new(fn {key, value} -> {sanitize_value(key), sanitize_value(value)} end)
    |> sanitize_event()
  end

  def sanitize(model_output), do: {:error, {:malformed_output, model_output}}

  @spec sanitize_value(term()) :: term()
  defp sanitize_value(str) when is_binary(str) do
    str =
      str
      |> String.downcase()
      |> String.trim()

    case Integer.parse(str) do
      {num, ""} -> num
      _otherwise -> str
    end
  end

  defp sanitize_value(value), do: value

  # Which operation did the model name, and — separately — does it carry a valid
  # operand? The two questions are independent, so answering them in one pass
  # would walk a matrix; answering them in turn walks two short lists.
  @spec sanitize_event(map()) :: {:ok, verdict()} | {:error, reason()}
  defp sanitize_event(sanitized) do
    with {:ok, event} <- parse_event(sanitized) do
      parse_ordinal(event, sanitized)
    end
  end

  @spec parse_event(map()) :: {:ok, event()} | {:error, :missing_event | {:unknown_event, term()}}
  defp parse_event(%{"event" => op}), do: parse_name(op)
  defp parse_event(_sanitized), do: {:error, :missing_event}

  @spec parse_name(term()) :: {:ok, event()} | {:error, {:unknown_event, term()}}
  defp parse_name("add"), do: {:ok, :add}
  defp parse_name("update"), do: {:ok, :update}
  defp parse_name("delete"), do: {:ok, :delete}
  defp parse_name("none"), do: {:ok, :noop}
  defp parse_name("noop"), do: {:ok, :noop}
  defp parse_name(op), do: {:error, {:unknown_event, op}}

  @spec parse_ordinal(event(), map()) ::
          {:ok, verdict()}
          | {:error,
             :missing_ordinal | {:malformed_ordinal, term()} | {:ordinal_out_of_range, integer()}}
  defp parse_ordinal(event, sanitized) when event in [:update, :delete] do
    case Map.fetch(sanitized, "id") do
      {:ok, id} when is_valid_id(id) -> {:ok, %{event: event, id: id}}
      {:ok, id} when is_integer(id) -> {:error, {:ordinal_out_of_range, id}}
      {:ok, id} -> {:error, {:malformed_ordinal, id}}
      :error -> {:error, :missing_ordinal}
    end
  end

  defp parse_ordinal(event, _sanitized), do: {:ok, %{event: event}}

  # ---------------------------------------------------------------------------#
  #                                Information Compare                         #
  # ---------------------------------------------------------------------------#

  @doc """
  Degrades an `UPDATE` to `:noop` when the candidate fact carries no more
  information than the memory it would replace.

  Algorithm 1's replacement is conditional —
  `if InformationContent(f) > InformationContent(m_i)` — so the model can choose
  `UPDATE` and the correct outcome still be nothing. That guard is a pure
  comparison over two contents, which puts it in the core: if the boundary
  evaluated it, the boundary would be deciding rather than performing.

  Every other operation passes through untouched, as does an `UPDATE` naming an
  id that is not among the candidates — which cannot happen via `parse/4`, since
  the id can only have come from the list in the first place.
  """
  @spec enforce_information_gain(t(), [Memory.t()], richer()) :: t()
  def enforce_information_gain(operation, candidates, richer? \\ &richer?/2)

  def enforce_information_gain({:update, id, fact} = operation, candidates, richer?) do
    case Enum.find(candidates, &(&1.id == id)) do
      %Memory{} = memory -> keep_if_richer(operation, richer?.(fact, memory))
      nil -> operation
    end
  end

  def enforce_information_gain(operation, _candidates, _richer?), do: operation

  @spec keep_if_richer(t(), boolean()) :: t()
  defp keep_if_richer(operation, true = _richer?), do: operation
  defp keep_if_richer(_operation, false = _richer?), do: :noop

  @doc """
  The default `InformationContent` comparison: strictly more whitespace-separated
  words in the candidate than in the memory.

  **This is a placeholder standing in for something the paper never defines.**
  Notes §7 lists token count, proposition count and an LLM judgement as all
  plausible and all behaving differently, and word count is only the cheapest of
  them to test against. It is deliberately visible and deliberately injectable:
  pass a different predicate to `parse/4` or `enforce_information_gain/3` and the
  guard stays where it belongs while the measure changes.

  Note the consequence of the strict comparison, which is a real cost and not an
  oversight: a same-length correction — `"lives in SF"` becoming
  `"lives in NY"` — degrades to `:noop`. Whichever measure eventually replaces
  this one has to handle that case; word count cannot.
  """
  @spec richer?(Fact.t(), Memory.t()) :: boolean()
  def richer?(%Fact{} = fact, %Memory{} = memory) do
    word_count(fact.content) > word_count(memory.content)
  end

  @spec word_count(String.t()) :: non_neg_integer()
  defp word_count(content), do: content |> String.split() |> length()
end
