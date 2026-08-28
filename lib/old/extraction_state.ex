defmodule Mem0.ExtractionState do
  @moduledoc """
  The extraction cursor: how far into a scope's message history extraction has
  read, so a pulse consumes each exchange once.

  Summaries derive their watermark from their own rows; extraction cannot — a
  pulse that extracts *zero* facts leaves no artifact, and the watermark must
  advance because messages were considered, not because facts came out. So the
  cursor is its own row: one per scope, updated in place.

  One writer, narrow charter: `Mem0.Reconcile`'s pulse writes it, nothing else
  does. No summary state, no memory counts — summaries already carry their own
  watermark, and a second copy here is a second source of truth to drift.
  """

  import Ecto.Query

  alias Mem0.Core.Scope
  alias Mem0.ExtractionState.Row
  alias Mem0.Repo

  @doc """
  The seq of the last message this scope's extraction consumed, or `nil` for a
  scope never pulsed — exactly the "no watermark" value
  `Mem0.Extract.facts_since/3` accepts.
  """
  @spec through_seq(Scope.t()) :: non_neg_integer() | nil
  def through_seq(%Scope{} = scope) do
    scope
    |> for_scope()
    |> select([row], row.through_seq)
    |> Repo.one()
  end

  @doc """
  Records that a pulse consumed messages through `through_seq`, at `at`.

  An upsert on the scope's unique index, and monotonic: two concurrent pulses
  both read watermark W and race to write; last-write-wins would let the loser
  drag the watermark *backwards*, and `GREATEST` makes arrival order
  irrelevant instead of locking it away. `pulsed_at` is set unconditionally —
  it means "last pulse", not "furthest pulse".
  """
  @spec advance(Scope.t(), non_neg_integer(), DateTime.t()) :: :ok | {:error, Exception.t()}
  def advance(%Scope{} = scope, through_seq, %DateTime{} = at)
      when is_integer(through_seq) and through_seq >= 0 do
    {:ok, _row} =
      scope
      |> Row.from_scope(through_seq, at)
      |> Repo.insert(
        on_conflict: conflict_update(),
        conflict_target: [:user_id, :app_id, :run_id]
      )

    :ok
  rescue
    exception in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, exception}
  end

  # `EXCLUDED` is the row the insert proposed, so `pulsed_at` and `updated_at`
  # take the newest pulse's instant whatever `GREATEST` decides about the
  # watermark.
  defp conflict_update do
    from(row in Row,
      update: [
        set: [
          through_seq: fragment("GREATEST(EXCLUDED.through_seq, ?)", row.through_seq),
          pulsed_at: fragment("EXCLUDED.pulsed_at"),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ]
    )
  end

  # The scope is matched exactly, `nil`s included — the cursor is per-address,
  # not per-cover.
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
