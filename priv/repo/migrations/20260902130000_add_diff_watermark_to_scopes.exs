defmodule Bighead.Repo.Migrations.AddDiffWatermarkToScopes do
  use Ecto.Migration

  def change do
    alter table(:scopes) do
      # The diff twin of `last_extracted_message_id`: the id of the last diff
      # guidelines were extracted from. Null means never.
      add :last_extracted_diff_id, :bigint
    end
  end
end
