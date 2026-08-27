defmodule Mem0.Repo.Migrations.CreateScopes do
  use Ecto.Migration

  def change do
    create table(:scopes, primary_key: false) do
      add :id, :text, primary_key: true
      add :user, :text, null: false
      add :project, :text
      add :session, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:scopes, [:user, :project, :session], nulls_distinct: false)
  end
end
