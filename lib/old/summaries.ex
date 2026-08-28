defmodule Mem0.Summaries do
  @moduledoc """
  The store for `Mem0.Core.Summary`: append a row per regeneration, read the
  latest back.
  """

  import Ecto.Query

  alias Mem0.Core.Scope
  alias Mem0.Core.Summary
  alias Mem0.Repo
  alias Mem0.Summaries.Row

  @doc """
  Writes `summary` as a new row, leaving every earlier row in place.
  """
  @spec put(Summary.t()) :: :ok | {:error, Exception.t()}
  def put(%Summary{} = summary) do
    {:ok, _row} = summary |> Row.from_summary() |> Repo.insert(log: false)
    :ok
  rescue
    exception in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, exception}
  end

  @doc """
  The latest summary in exactly `scope`, or `nil` if none was ever stored.
  Latest means the one that was built on the biggest message history.
  """
  @spec latest(Scope.t()) :: Summary.t() | nil
  def latest(%Scope{} = scope) do
    scope
    |> for_scope()
    |> order_by([row], desc: row.through_seq, desc: row.id)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> nil
      %Row{} = row -> Row.to_summary(row)
    end
  end

  defp for_scope(%Scope{} = scope) do
    Row
    |> where([row], row.user_id == ^scope.user_id)
    |> narrow(:app_id, scope.app_id)
    |> narrow(:run_id, scope.run_id)
  end

  # `field == ^nil` is never true in SQL, and Ecto refuses to build it — a nil
  # id has to become `IS NULL` rather than a dropped clause.
  defp narrow(query, field, nil), do: where(query, [row], is_nil(field(row, ^field)))
  defp narrow(query, field, value), do: where(query, [row], field(row, ^field) == ^value)
end
