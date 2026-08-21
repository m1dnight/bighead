defmodule Mem0.Core.ScopeQuery do
  @moduledoc """
  This struct is similar to `Scope` but is used to read memories rather than
  write them.

  User id is required, but the others are optional. Filling in those fields
  narrows the search for memories further. Leaving them nil broadens the scope.
  """

  use TypedStruct

  typedstruct enforce: true do
    field :user_id, String.t()
    field :app_id, String.t(), enforce: false
    field :run_id, String.t(), enforce: false
  end

  @doc """
  Builds a read filter. `user_id` is required and must be non-nil; `app_id` and
  `run_id` default to `nil`, meaning *any value at that level*.
  """
  @spec new(keyword()) :: t()
  def new(fields) do
    fields
    |> Keyword.put_new(:app_id, nil)
    |> Keyword.put_new(:run_id, nil)
    |> then(&struct!(__MODULE__, &1))
    |> validate_user_id()
  end

  defp validate_user_id(%__MODULE__{user_id: user_id} = query) when is_binary(user_id), do: query

  defp validate_user_id(%__MODULE__{}) do
    raise ArgumentError,
          "ScopeQuery.user_id must be a non-nil string: a nil there reads every user"
  end
end
