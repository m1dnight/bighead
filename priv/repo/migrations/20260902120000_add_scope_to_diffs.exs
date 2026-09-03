defmodule Bighead.Repo.Migrations.AddScopeToDiffs do
  use Ecto.Migration

  def up do
    # Existing rows predate scopes on diffs and carry no session to point
    # at, so they cannot be backfilled. They are disposable dev data: the
    # hook posts every ledger transition afresh.
    execute "DELETE FROM diffs"

    alter table(:diffs) do
      # No on_delete policy, as for messages and facts: deleting a scope
      # that still has diffs should fail loudly, not cascade.
      add :scope_id, references(:scopes), null: false
    end
  end

  def down do
    alter table(:diffs) do
      remove :scope_id
    end
  end
end
