defmodule Mem0.Messages do
  @moduledoc """
  The store for `Mem0.Core.Message`: messages in, the same messages out.

  Its public functions take and return core structs, so nothing that calls it
  grows an Ecto dependency. `Mem0.Messages.Row` is the only thing that knows
  there is a table, and this is the only module allowed to know `Row` exists.

  Nothing calls this yet. Where the write is triggered from — `Mem0.Ingest`,
  the controller, or somewhere else — is a separate decision, and the
  overlapping-tail question it raises is better answered against a table that
  already exists.
  """

  import Ecto.Query

  alias Mem0.Core.Message
  alias Mem0.Core.Scope
  alias Mem0.Messages.Row
  alias Mem0.Repo

  @doc """
  Writes `messages`, returning how many rows landed.

  One `insert_all/3` for the whole batch, with a single `inserted_at` stamped
  across it. `on_conflict: :nothing` on the id makes putting the same batch
  twice a no-op rather than a constraint violation — the minimum needed to make
  this safe to call twice. Whether that is the *right* dedup policy is the
  overlapping-tail question, and it is not answered here.

  `log: false` is on this insert specifically, and not on the repo, because
  Ecto logs query parameters and here those parameters are the transcript.
  `insert_all/3` logs at `:debug`, dev runs at `:debug`, and that path goes
  around the parameter filtering in `config/config.exs`.

  An empty batch is `{:ok, 0}` and issues no query.
  """
  @spec put([Message.t()]) :: {:ok, non_neg_integer()} | {:error, Exception.t()}
  def put([]), do: {:ok, 0}

  def put(messages) when is_list(messages) do
    # insert_all does not auto-populate the inserted_at field, so we have to do it here.
    inserted_at = DateTime.utc_now()
    rows = Enum.map(messages, &Row.from_message(&1, inserted_at))

    {count, nil} =
      Repo.insert_all(Row, rows, on_conflict: :nothing, conflict_target: :id, log: false)

    {:ok, count}
  rescue
    exception in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, exception}
  end

  @doc """
  This run's messages, ordered by `seq`.

  No `log: false` here: the parameters are scope ids, and Ecto does not log
  result rows.
  """
  @spec for_run(Scope.t()) :: [Message.t()]
  def for_run(%Scope{} = scope) do
    scope
    |> for_scope()
    |> order_by([row], asc: row.seq)
    |> Repo.all()
    |> Enum.map(&Row.to_message/1)
  end

  @doc """
  How many of this run's transcript lines mem0's copy already accounts for.

  This is required for backfilling. When a Stop hook is called, it needs to know
  which lines of the transcript that need to be submitted still.
  """
  @spec lines_seen(Scope.t()) :: non_neg_integer()
  def lines_seen(%Scope{} = scope) do
    scope
    |> for_scope()
    |> order_by([row], desc: row.seq)
    |> limit(1)
    |> select([row], row.seq)
    |> Repo.one()
    |> case do
      nil -> 0
      seq when is_integer(seq) -> seq + 1
    end
  end

  # The scope is matched exactly, `nil`s included — one run's own transcript,
  # not the widening ladder `Mem0.Core.Scope.covering/1` describes.
  defp for_scope(%Scope{} = scope) do
    Row
    |> where([row], row.user_id == ^scope.user_id)
    |> narrow(:app_id, scope.app_id)
    |> narrow(:run_id, scope.run_id)
  end

  # `field == ^nil` is never true in SQL, and Ecto refuses to build it. A nil
  # id is an address in its own right here — "the messages that belong to no
  # app" — so it has to become `IS NULL` rather than a dropped clause.
  defp narrow(query, field, nil), do: where(query, [row], is_nil(field(row, ^field)))
  defp narrow(query, field, value), do: where(query, [row], field(row, ^field) == ^value)
end
