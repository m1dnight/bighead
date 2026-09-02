defmodule Mem0.Repo.Migrations.CreateDiffs do
  use Ecto.Migration

  def change do
    create table(:diffs) do
      add :file, :text, null: false
      add :diff, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # A diff is unique on file and hash of its text, so resubmitting the same
    # diff — hook scripts recompute transitions from the whole ledger — lands
    # on the existing row instead of accumulating copies.
    create unique_index(:diffs, ["file", "md5(diff)"], name: :diffs_file_diff_index)
  end
end
