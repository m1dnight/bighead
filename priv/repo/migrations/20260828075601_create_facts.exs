defmodule Mem0.Repo.Migrations.CreateFacts do
  use Ecto.Migration

  def change do
    create table(:facts) do
      add :scope_id, references(:scopes), null: false
      add :fact, :text, null: false
      # Nullable: embeddings are computed asynchronously after insert. NULL
      # honestly means "not computed yet" — a zero placeholder would make
      # pgvector's cosine distance NaN.
      add :embedding_768, :vector, size: 768

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:facts, ["scope_id", "md5(fact)"], name: :facts_scope_fact_index)
  end
end
