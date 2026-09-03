defmodule Bighead.Repo.Migrations.AddOriginToDiffs do
  use Ecto.Migration

  def change do
    alter table(:diffs) do
      # How the change came about: "manual" for a hand edit of the agent's
      # code, "requested" for an edit the agent made on the developer's
      # prompt. Nullable: rows from before the hook sent it have none.
      add :origin, :string
    end
  end
end
