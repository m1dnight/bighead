defmodule Mem0.Core.LayeringTest do
  @moduledoc """
  Turns the three rules of Phase 2 into a CI failure rather than a habit.

  Grep would miss `apply/3`, aliased calls and macro-generated references. The
  BEAM import table does not: every external call a module makes is in there,
  fully qualified, whatever it looked like in source.
  """
  use ExUnit.Case, async: true

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

  defp external_calls(module) do
    {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(:code.which(module), [:imports])
    imports
  end

  defp forbidden?(module) do
    name = Atom.to_string(module)

    module in @forbidden_modules or Enum.any?(@forbidden_prefixes, &String.starts_with?(name, &1))
  end
end
