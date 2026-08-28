defmodule Mem0.Core.Scored do
  @moduledoc """
  Something scored is any struct that has been cosine compared to something
  else. For example, two sentences are compared to check if they are talking
  about the same thing. The score will
  """

  @typedoc "A candidate and the similarity score it was retrieved with."
  @type t(a) :: {float(), a}

  @doc """
  Given a list of `Scored` structs, orders them from high to low.
  """
  @spec rank([t(a)]) :: [t(a)] when a: var
  def rank(candidates), do: Enum.sort_by(candidates, &elem(&1, 0), :desc)

  @doc """
  Given a list of `Scored` items, it will return the candidates that are above
  the given threshold.
  """
  @spec above([t(a)], float()) :: [t(a)] when a: var
  def above(candidates, threshold) when is_float(threshold) do
    Enum.filter(candidates, fn {score, _thing} -> score >= threshold end)
  end
end
