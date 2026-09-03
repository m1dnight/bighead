defmodule Bighead.Repo.Migrations.CreateSummaries do
  use Ecto.Migration

  def change do
    # Append-only, one row per regeneration — not an upsert. Not because the
    # previous text is an input (under regeneration it never is), but because
    # append-plus-latest is the simplest write that is correct: a plain
    # insert, no conflict target to invent on a table with no natural unique
    # key, and a failed regeneration leaves the old row latest with no
    # compensating code. This is *not* the memories table's
    # append-mostly-with-supersession discipline; summaries are rebuildable
    # derived data and need no audit semantics.
    #
    # The default integer id stays: the table wants a primary key, it is the
    # `latest/1` tiebreak between two rows at the same watermark, and it never
    # crosses the boundary — `Bighead.Core.Summary` has no id field.
    create table(:summaries) do
      add :user_id, :text, null: false
      # Nullable even though this phase only ever writes run-scoped rows.
      # `Bighead.Core.Scope`'s optional ids are nullable by construction;
      # per-run-ness is a policy of the callers this phase deliberately does
      # not have, and `null: false` on `run_id` would encode that policy where
      # only a migration can change it.
      add :app_id, :text
      add :run_id, :text
      add :text, :text, null: false
      # The highest `seq` the generation read — the staleness watermark, in
      # the same units `messages.seq` uses.
      add :through_seq, :integer, null: false
      add :generated_at, :utc_datetime_usec, null: false
      # A regeneration is never edited, so there is no `updated_at`.
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Covers the only read there is: `latest/1`'s exact-scope match, ordered
    # by `through_seq`.
    create index(:summaries, [:user_id, :app_id, :run_id, :through_seq])
  end
end
