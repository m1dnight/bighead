defmodule Mem0.Repo.Migrations.AddKindToFacts do
  use Ecto.Migration

  def change do
    alter table(:facts) do
      # Which extractor produced the fact: "fact" for the transcript
      # extractor, "guideline" for the diff extractor. The default labels
      # every existing row a fact; guidelines stored before this column
      # cannot be told apart from them.
      add :kind, :string, null: false, default: "fact"
    end
  end
end
