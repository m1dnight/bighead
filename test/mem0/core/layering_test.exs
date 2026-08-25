defmodule Mem0.Core.LayeringTest do
  @moduledoc """
  Turns the layering rules into a CI failure rather than a habit.

  Grep would miss `apply/3`, aliased calls and macro-generated references. The
  BEAM import table does not: every external call a module makes is in there,
  fully qualified, whatever it looked like in source.
  """
  use ExUnit.Case, async: true

  alias Mem0.Embedder.Ollama
  alias Mem0.LLM.Anthropic
  alias Mem0.Messages.Row

  @forbidden_modules [
    Ecto,
    Mem0.Repo,
    GenServer,
    Agent,
    Supervisor,
    Task,
    Req,
    Phoenix
  ]

  @forbidden_prefixes ["Elixir.Ecto.", "Elixir.Phoenix.", "Elixir.Req.", "Elixir.Swoosh."]

  # Phase 3's rule: the ports are behaviours, and the adapters behind them are
  # the only modules allowed to speak HTTP. Anything else appearing in the list
  # below means an adapter's job leaked into one of its callers. `Mem0.ReqEcho`
  # is test support — a `Req` adapter that answers without a socket.
  @http_adapters [Ollama, Anthropic, Mem0.ReqEcho]

  # Time arrives as an argument. This is what makes the interval and staleness
  # predicates testable without `Process.sleep`, and it is the precondition for
  # a `Clock` port later rather than an afterthought.
  @clock_calls [
    {DateTime, :utc_now},
    {NaiveDateTime, :utc_now},
    {Date, :utc_today},
    {Time, :utc_now},
    {:os, :timestamp},
    {:os, :system_time},
    {:erlang, :system_time},
    {:erlang, :monotonic_time},
    {:calendar, :universal_time},
    {:calendar, :local_time}
  ]

  setup_all do
    {:ok, modules} = :application.get_key(:mem0, :modules)

    core =
      Enum.filter(modules, fn module ->
        String.starts_with?(Atom.to_string(module), "Elixir.Mem0.Core.")
      end)

    # A layering test that passes because it found nothing is not a test.
    assert length(core) > 10

    {:ok, core_modules: core}
  end

  test "no core module reaches persistence, processes or HTTP", %{core_modules: modules} do
    offenders =
      for module <- modules,
          {called, function, arity} <- external_calls(module),
          forbidden?(called),
          do: {module, called, function, arity}

    assert [] == offenders
  end

  test "no core function reads a clock", %{core_modules: modules} do
    offenders =
      for module <- modules,
          {called, function, _arity} <- external_calls(module),
          {called, function} in @clock_calls,
          do: {module, called, function}

    assert [] == offenders
  end

  test "no core struct holds an embedding", %{core_modules: modules} do
    offenders =
      for module <- modules,
          function_exported?(module, :__struct__, 0),
          :embedding in Map.keys(module.__struct__()),
          do: module

    assert [] == offenders
  end

  test "the adapters are the only modules that reach an HTTP client" do
    {:ok, modules} = :application.get_key(:mem0, :modules)

    offenders =
      for module <- modules,
          module not in @http_adapters,
          {called, _function, _arity} <- external_calls(module),
          String.starts_with?(Atom.to_string(called), "Elixir.Req"),
          do: module

    assert [] == Enum.uniq(offenders)
  end

  # Phase 6's rule: the messages table belongs to `Mem0.Messages` alone. `Row`
  # is a table shape rather than a second domain type, and `Repo` is how it
  # reaches the table — a module that names either has grown a persistence
  # dependency it was supposed to be spared. `Mem0.Repo` is its own caller
  # through the functions `use Ecto.Repo` generates.
  @persistence [Mem0.Repo, Row]
  @persistence_owners [Mem0.Messages, Mem0.Repo]

  test "only Mem0.Messages reaches the messages table" do
    {:ok, modules} = :application.get_key(:mem0, :modules)

    offenders =
      for module <- modules,
          module not in @persistence_owners,
          {called, _function, _arity} <- external_calls(module),
          called in @persistence,
          do: module

    assert [] == Enum.uniq(offenders)
  end

  defp external_calls(module) do
    {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(:code.which(module), [:imports])
    imports
  end

  defp forbidden?(module) do
    name = Atom.to_string(module)

    module in @forbidden_modules or Enum.any?(@forbidden_prefixes, &String.starts_with?(name, &1))
  end
end
