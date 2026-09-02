defmodule Util do
  @moduledoc """
  Utility functions to express list operations.
  """

  @doc """
  Maps a function over a list and returns an error as soon as one of the
  applications fails.  Similar to Haskell's `mapM`.
  """
  @spec traverse([a], (a -> {:ok, b} | {:error, term()})) :: {:ok, [b]} | {:error, term()}
        when a: var, b: var
  def traverse(list, fun) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} ->
          {:cont, {:ok, [value | acc]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} ->
        {:ok, Enum.reverse(acc)}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Maps a function over a list and partitions the results: the successful
  values in the first list, the error reasons in the second, both in input
  order.  Similar to Haskell's `partitionEithers`.
  """
  @spec partition_map(Enumerable.t(a), (a -> {:ok, b} | {:error, c})) :: {[b], [c]}
        when a: var, b: var, c: var
  def partition_map(list, fun) do
    {oks, errors} =
      Enum.reduce(list, {[], []}, fn item, {oks, errors} ->
        case fun.(item) do
          {:ok, value} ->
            {[value | oks], errors}

          {:error, reason} ->
            {oks, [reason | errors]}
        end
      end)

    {Enum.reverse(oks), Enum.reverse(errors)}
  end


end
