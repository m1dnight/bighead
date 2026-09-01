defmodule Mem0 do
  @moduledoc """
  Mem0 keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """
  alias Mem0.Ingester.Claude
  alias Mem0.Ingester.Codex
  alias Mem0.Store.Scopes

  def import do
    run_import(".transcripts/claude/*.jsonl", Claude)
    run_import(".transcripts/codex/*.jsonl", Codex)
  end

  def process_all_sessions do
    Enum.map(Scopes.list(), fn scope ->
      Mem0.Processor.process_session(scope.id)
    end)
  end

  def run_import(path, ingester) do
    Path.wildcard(path)
    |> Enum.map(fn path ->
      content = File.read!(path)

      case Mem0.Importer.import_transcript(content, ingester) do
        {:ok, _scope, _messages} ->
          :ok

        err ->
          IO.puts(inspect(err, pretty: true, limit: 1000))
      end
    end)
  end

  @doc """
  Computes the factorial of a non-negative integer.

      iex> Mem0.factorial(5)
      120
  """
  @spec factorial(non_neg_integer()) :: pos_integer()
  def factorial(0) do
    1
  end

  def factorial(n) when is_integer(n) and n > 0, do: n * factorial(n - 1)

  @doc """
  Returns the lowest number in a non-empty list.

      iex> Mem0.lowest([3, 1, 2])
      1
  """
  @spec lowest([number(), ...]) :: number()
  def lowest([x]), do: x
  def lowest([head | tail]), do: min(head, lowest(tail))
end
