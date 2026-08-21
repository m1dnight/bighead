defmodule Mem0.Core.Scope do
  @moduledoc """
  The scope of a fact is the context to which it belongs. The `user_id` is
  always required, but `app_id` and `run_id` are not.

  A fact belonging to `{user_id_1, app_id_1, run_id_1}` will be found by looking
  for facts on the scope `{user_id_1, app_id_1, nil}` or `{user_id_1, nil,
  nil}`.

  But facts belonging to `{user_id_1, app_id_1, run_id_1}` will not be found
  under the scope `{user_id_2, app_id_2, run_id_2}`.

  A fact with scope `{user_id_1, nil, nil}` is considered "global" for that user
  id.
  """

  use TypedStruct

  alias Mem0.Core.ScopeQuery

  typedstruct enforce: true do
    field :user_id, String.t()
    field :app_id, String.t(), enforce: false
    field :run_id, String.t(), enforce: false
  end

  @doc """
  Builds a write address.

  Ids are trimmed. A blank optional id normalises to `nil`, which is the same
  address a missing one gives — so `new/1` is idempotent over its own output. A
  blank `user_id` raises rather than normalising, for the reason in the module
  doc.

  ## Examples

  A full address — this session, in this repo, for this user:

      iex> scope = Scope.new(user_id: "christophe", app_id: "mem0", run_id: "session-1")
      iex> {scope.user_id, scope.app_id, scope.run_id}
      {"christophe", "mem0", "session-1"}

  A fact about the user that belongs to no project and no session:

      iex> scope = Scope.new(user_id: "christophe")
      iex> {scope.app_id, scope.run_id}
      {nil, nil}

  Ids are trimmed, and a blank optional id lands on the same address a missing
  one gives — which is what makes `new/1` idempotent over its own output:

      iex> scope = Scope.new(user_id: " christophe ", app_id: "mem0", run_id: "  ")
      iex> {scope.user_id, scope.run_id}
      {"christophe", nil}

  A blank `user_id` is the one that will not normalise, because the value it
  would normalise to addresses every user at once:

      iex> Scope.new(user_id: "  ")
      ** (ArgumentError) Scope.user_id must be a non-blank string: a nil or blank there addresses every user

  """
  @spec new(keyword()) :: t()
  def new(fields) do
    fields
    |> Keyword.put_new(:app_id, nil)
    |> Keyword.put_new(:run_id, nil)
    |> then(&struct!(__MODULE__, &1))
    |> normalize()
  end

  defp normalize(%__MODULE__{} = scope) do
    %{
      scope
      | user_id: normalize_user_id(scope.user_id),
        app_id: blank_to_nil(scope.app_id),
        run_id: blank_to_nil(scope.run_id)
    }
  end

  defp normalize_user_id(user_id) when is_binary(user_id) do
    case String.trim(user_id) do
      "" -> raise ArgumentError, blank_user_id_message()
      trimmed -> trimmed
    end
  end

  defp normalize_user_id(_not_a_string), do: raise(ArgumentError, blank_user_id_message())

  defp blank_user_id_message do
    "Scope.user_id must be a non-blank string: a nil or blank there addresses every user"
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @doc """
  The ladder of read filters a read happening at this address should see, in
  **widening** order: the exact run first, then the app with any run, then the
  user with any app.

  ## Examples

  Every rung keeps the `user_id` — the ladder widens across apps and runs, never
  across users — so these examples show only the two levels that move:

      iex> scope = Scope.new(user_id: "christophe", app_id: "mem0", run_id: "session-1")
      iex> Enum.map(Scope.covering(scope), &{&1.app_id, &1.run_id})
      [{"mem0", "session-1"}, {"mem0", nil}, {nil, nil}]

  A rung a nil makes redundant is dropped rather than repeated. With no run to
  be exact about, the ladder starts at the app:

      iex> scope = Scope.new(user_id: "christophe", app_id: "mem0")
      iex> Enum.map(Scope.covering(scope), &{&1.app_id, &1.run_id})
      [{"mem0", nil}, {nil, nil}]

  And a user-level address collapses to a single rung:

      iex> scope = Scope.new(user_id: "christophe")
      iex> Enum.map(Scope.covering(scope), &{&1.app_id, &1.run_id})
      [{nil, nil}]

  A run with no app above it keeps its rung, because "this session, whatever the
  app" is still narrower than "this user, anywhere":

      iex> scope = Scope.new(user_id: "christophe", run_id: "session-1")
      iex> Enum.map(Scope.covering(scope), &{&1.app_id, &1.run_id})
      [{nil, "session-1"}, {nil, nil}]

  """
  @spec covering(t()) :: [ScopeQuery.t()]
  def covering(%__MODULE__{} = scope) do
    Enum.dedup([
      ScopeQuery.new(user_id: scope.user_id, app_id: scope.app_id, run_id: scope.run_id),
      ScopeQuery.new(user_id: scope.user_id, app_id: scope.app_id),
      ScopeQuery.new(user_id: scope.user_id)
    ])
  end
end
