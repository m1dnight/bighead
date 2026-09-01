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
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = error -> error
    end
  end
end
