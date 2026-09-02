defmodule Mem0.Repo.Migrations.RecreateMessagesWithScope do
  use Ecto.Migration

  def change do
    # Drop-and-recreate rather than alter: the (user_id, app_id, run_id)
    # triple moves to the scopes table, and existing rows have no scope to
    # point at. Rows are disposable — re-ingest via the backfill endpoint.
    # Makes this migration irreversible.
    drop table(:messages)

    create table(:messages) do
      # No on_delete policy: deleting a scope that still has messages should
      # fail loudly, not cascade.
      add :scope_id, references(:scopes), null: false
      add :role, :text, null: false
      add :content, :text, null: false
      add :timestamp, :utc_datetime_usec, null: false
      add :embedding_768, :vector, size: 768
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # A message is unique on scope, timestamp, role, and hash of content.
    create unique_index(:messages, ["scope_id", "\"timestamp\"", "role", "md5(content)"],
             name: :messages_scope_timestamp_role_content_index
           )
  end
end
