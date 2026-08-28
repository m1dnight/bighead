defmodule Mem0.Repo.Migrations.CreateScopes do
  use Ecto.Migration

  def change do
    create table(:scopes) do
      add :user, :text, null: false
      add :project, :text
      add :session, :text
      add :last_extracted_message_id, :bigint

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:scopes, [:user, :project, :session], nulls_distinct: false)
    create unique_index(:scopes, [:session])
  end
end
