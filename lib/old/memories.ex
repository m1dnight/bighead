defmodule Mem0.Memories do
  @moduledoc """
  The context to read memories form the database.
  """

  import Ecto.Query
  import Pgvector.Ecto.Query

  alias Mem0.Core.Fact
  alias Mem0.Core.Memory
  alias Mem0.Core.ScopeQuery
  alias Mem0.Core.Scored
  alias Mem0.Memories.Row
  alias Mem0.Repo

  @doc """
  The ADD arm's storage half, and where the id is minted.

  `Ecto.UUID.generate/0`, then `Memory.from_fact/3` — the core constructor
  already says what a born memory looks like (`created_at == updated_at ==
  at`), and this function's job is to persist that sentence, not restate it.
  Returns the built `Memory`, because the caller needs the id it did not
  choose.

  `at` is an argument rather than a clock read inside: the update phase will
  stamp one instant across a whole reconciliation pulse, and a store that
  reads its own clock would scatter that instant.

  `log: false` because the insert's parameters are memory content — the same
  Ecto-logs-parameters path Phase 6 closed for transcripts.
  """
  @spec add(Fact.t(), [float()], DateTime.t()) :: {:ok, Memory.t()} | {:error, Exception.t()}
  def add(%Fact{} = fact, embedding, %DateTime{} = at) when is_list(embedding) do
    memory = Memory.from_fact(Ecto.UUID.generate(), fact, at)
    {:ok, _row} = memory |> Row.from_memory(embedding) |> Repo.insert(log: false)
    {:ok, memory}
  rescue
    exception in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, exception}
  end

  @doc """
  The UPDATE arm's storage half, and deliberately dumb.

  The caller has already applied `Memory.apply_update/3`; the core
  transforms, the store persists. Writes `content`, `extracted_at`,
  `event_time`, `source_message_ids`, `updated_at` and the vector over the
  row — `created_at` untouched, id surviving, exactly Algorithm 1's UPDATE.
  The fresh vector is not optional: the content changed, and an updated
  memory still findable by its old vector is the paper's UPDATE with the
  retrieval half forgotten.

  Guarded on `superseded_at IS NULL`: updating a dead memory means the caller
  is acting on a stale candidate list, and zero rows updated comes back as
  `{:error, :not_found}` — one error for one meaning, "no *active* memory by
  that id", covering absent and already-dead alike because the caller's next
  move is the same for both.
  """
  @spec update(Memory.t(), [float()]) :: :ok | {:error, :not_found | Exception.t()}
  def update(%Memory{} = memory, embedding) when is_list(embedding) do
    Row
    |> where([row], row.id == ^memory.id and is_nil(row.superseded_at))
    |> Repo.update_all(
      [
        set: [
          content: memory.content,
          embedding: Pgvector.new(embedding),
          extracted_at: memory.extracted_at,
          event_time: memory.event_time,
          source_message_ids: memory.source_message_ids,
          updated_at: memory.updated_at
        ]
      ],
      log: false
    )
    |> case do
      {1, nil} -> :ok
      {0, nil} -> {:error, :not_found}
    end
  rescue
    exception in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, exception}
  end

  @doc """
  The DELETE arm, and removes nothing.

  Sets `superseded_at` — and `superseded_by_id` when the caller passes `by:`;
  `{:delete, id}` carries no replacement fact, so whether the link gets set
  is the caller's affair. Guarded on `superseded_at IS NULL` like `update/2`,
  for the same reason and with the same error: superseding an already-dead
  memory changes nothing and is `{:error, :not_found}`.
  """
  @spec supersede(Memory.id(), DateTime.t(), keyword()) ::
          :ok | {:error, :not_found | Exception.t()}
  def supersede(id, %DateTime{} = at, opts \\ []) when is_binary(id) do
    opts = Keyword.validate!(opts, [:by])

    set =
      case Keyword.fetch(opts, :by) do
        {:ok, by} -> [superseded_at: at, superseded_by_id: by]
        :error -> [superseded_at: at]
      end

    Row
    |> where([row], row.id == ^id and is_nil(row.superseded_at))
    |> Repo.update_all(set: set)
    |> case do
      {1, nil} -> :ok
      {0, nil} -> {:error, :not_found}
    end
  rescue
    exception in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, exception}
  end

  @doc """
  The top-`s` read of notes §2.2: active rows in the query's cover, ranked by
  cosine similarity to `embedding`, truncated to `max_memories`.

  The score is `1 - cosine_distance`, so high is close — the orientation
  `Scored.rank/1` and `Scored.above/2` already assume. Ranked by
  construction; thresholding stays the caller's move via `Scored.above/2`,
  and `max_memories` is an argument because the paper's `s = 10` is
  update-phase policy, not a property of this store.
  """
  @spec search(ScopeQuery.t(), [float()], max_memories :: pos_integer()) ::
          [Scored.t(Memory.t())]
  def search(%ScopeQuery{} = query, embedding, max_memories)
      when is_list(embedding) and is_integer(max_memories) and max_memories > 0 do
    vector = Pgvector.new(embedding)

    query
    |> for_query()
    |> order_by([row], asc: cosine_distance(row.embedding, ^vector))
    |> limit(^max_memories)
    |> select([row], {cosine_distance(row.embedding, ^vector), row})
    |> Repo.all()
    |> Enum.map(fn {distance, row} -> {1.0 - distance, Row.to_memory(row)} end)
  end

  @doc """
  Function to read back all the active memories for testing and debugging
  purposes. Otherwise the only way to read back memories is via search.
  """
  @spec active(ScopeQuery.t()) :: [Memory.t()]
  def active(%ScopeQuery{} = query) do
    query
    |> for_query()
    |> order_by([row], asc: row.created_at)
    |> Repo.all()
    |> Enum.map(&Row.to_memory/1)
  end

  # Every read this store exposes filters to active rows in the query's
  # cover. `user_id` is always an equality — `ScopeQuery.new/1` refuses a nil
  # there — and the optional levels broaden on nil: no clause at all, the
  # opposite of the write-side `IS NULL` in the messages store's `narrow/3`.
  defp for_query(%ScopeQuery{} = query) do
    Row
    |> where([row], is_nil(row.superseded_at))
    |> where([row], row.user_id == ^query.user_id)
    |> broaden(:app_id, query.app_id)
    |> broaden(:run_id, query.run_id)
  end

  defp broaden(query, _field, nil), do: query
  defp broaden(query, field, value), do: where(query, [row], field(row, ^field) == ^value)
end
