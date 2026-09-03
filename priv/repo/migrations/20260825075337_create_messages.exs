defmodule Bighead.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages, primary_key: false) do
      # `:text`, not `:uuid`. Every id is a Claude Code uuid today, but
      # `Bighead.Core.Message.id/0` is `String.t()` by design and a second
      # transcript format is under no obligation to use uuids. A text column
      # costs an index page or two; a uuid column costs a migration on a
      # populated table the first time one does not.
      add :id, :text, primary_key: true
      add :user_id, :text, null: false
      add :app_id, :text
      add :run_id, :text
      # `:text`, not a Postgres enum. Extending an enum is a migration; the
      # closed set already lives in `Bighead.Core.Message.role/0`.
      add :role, :text, null: false
      add :content, :text, null: false
      # Claude Code stamps milliseconds and `:utc_datetime` truncates them
      # silently, which would leave two messages in the same second orderable
      # only by `seq`.
      add :said_at, :utc_datetime_usec, null: false
      add :seq, :integer, null: false
      # Created and left NULL, never zero-filled: pgvector's cosine distance
      # against a zero vector yields NaN, and NaN sorts *ahead* of every real
      # distance in an ORDER BY. NULL is skipped, and it is honest about
      # meaning "not computed".
      #
      # 768 is the value of `config :bighead, :embedder, :dimensions`, hardcoded
      # here on purpose — a migration that changes shape with runtime
      # configuration is not a migration. No HNSW or IVFFlat index; an index
      # over NULLs is pure cost.
      add :embedding, :vector, size: 768
      # What was said was said, so there is no `updated_at`.
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Covers the only read this phase makes, and its prefix matches the shape
    # `Bighead.Core.Scope.covering/1` will want later.
    #
    # Deliberately not unique. A unique index on (user_id, app_id, run_id, seq)
    # looks right and would fail a whole batch over a cosmetic duplicate; left
    # out until the overlapping-tail question is actually answered.
    create index(:messages, [:user_id, :app_id, :run_id, :seq])
  end
end
