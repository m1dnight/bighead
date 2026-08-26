defmodule Mem0.Repo.Migrations.CreateExtractionState do
  use Ecto.Migration

  def change do
    create table(:extraction_state) do
      add :user_id, :text, null: false
      add :app_id, :text
      add :run_id, :text
      add :through_seq, :integer, null: false
      add :pulsed_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    # The scope is the identity but cannot be the primary key: PK columns must
    # be NOT NULL, and a nil app_id is a legitimate address. Hence the default
    # bigserial id plus this unique index — which must be `nulls_distinct:
    # false` (Postgres 15+). In a default unique index NULL ≠ NULL, so a bare
    # `{user, nil, nil}` scope would grow a second row on every pulse,
    # `ON CONFLICT` would never fire, and every read of that scope's watermark
    # would be ambiguous. No sentinel values: coalescing nil to "" in the row
    # would re-introduce exactly the blank-versus-nil ambiguity `Scope.new/1`
    # exists to remove.
    create unique_index(:extraction_state, [:user_id, :app_id, :run_id], nulls_distinct: false)
  end
end
