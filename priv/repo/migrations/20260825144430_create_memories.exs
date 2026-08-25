defmodule Mem0.Repo.Migrations.CreateMemories do
  use Ecto.Migration

  def change do
    create table(:memories, primary_key: false) do
      # `:uuid`, not the messages table's `:text` — that argument does not
      # transfer. Message ids arrive from a transcript format with no
      # obligation to be uuids; memory ids are minted here and nowhere else,
      # forever. Plain v4: the id leaks outward by design (considered_ids,
      # telemetry metadata), and time-order already lives in `created_at`.
      add :id, :uuid, primary_key: true
      add :user_id, :text, null: false
      add :app_id, :text
      add :run_id, :text
      add :content, :text, null: false
      # `null: false` — the opposite of the messages column, for the opposite
      # reason. There, NULL honestly means "not computed" and nothing reads
      # the column. Here the vector is how a memory is found by the only read
      # that matters; a memory without one is unfindable, which is a bug, and
      # NOT NULL turns that bug into a constraint violation at write time
      # instead of a silent retrieval gap.
      #
      # 768 is the value of `config :mem0, :embedder, :dimensions`, hardcoded
      # here on purpose — a migration that changes shape with runtime
      # configuration is not a migration.
      add :embedding, :vector, size: 768, null: false
      add :extracted_at, :utc_datetime_usec, null: false
      add :event_time, :utc_datetime_usec
      # Provenance is read whole or not at all; nothing queries "which
      # memories cite message m", and a join table is a migration away if
      # something ever does.
      add :source_message_ids, {:array, :text}, null: false, default: []
      # The paper's DELETE becomes supersession: `superseded_at` set, row
      # kept, every read filtered to active. `superseded_by_id` is nullable
      # and self-referencing — "a superseded memory knows it came before the
      # one replacing it" needs somewhere to point, but `{:delete, id}`
      # carries no replacement fact, so whether the link gets set is the
      # caller's affair. The FK costs nothing on a single-row write and keeps
      # garbage ids out.
      add :superseded_at, :utc_datetime_usec
      add :superseded_by_id, references(:memories, type: :uuid, column: :id)
      # The domain's own columns, not `timestamps/1`. A memory is *born in
      # the store* — its domain `created_at` and a bookkeeping `inserted_at`
      # would record the same instant twice. All four timestamps are written
      # from the struct, none Ecto-managed.
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    # Partial on active: it covers the filter half of every read this store
    # has, and dead rows — which only accumulate — never bloat it. No HNSW or
    # IVFFlat: exact KNN via `ORDER BY embedding <=> $1` is *correct*, the
    # scan is bounded by one user's active memories, and an ANN index is an
    # optimization with a measurable trigger.
    create index(:memories, [:user_id, :app_id, :run_id], where: "superseded_at IS NULL")
  end
end
