defmodule Bighead.Repo.Migrations.EnableExtensions do
  use Ecto.Migration

  # This migration must stand alone. Postgrex resolves type OIDs when a
  # connection opens, and the connection running migrations opens *before*
  # `CREATE EXTENSION vector` executes here. So no migration may bind a
  # `vector` parameter in the same `mix ecto.migrate` run that creates the
  # extension.
  #
  # `pg_trgm` and `unaccent` are for the lexical retrieval channel, several
  # phases away. They are enabled now because `CREATE EXTENSION` requires
  # superuser on most managed Postgres offerings, and the whole permission
  # surface is worth learning once.

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS vector")
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")
    execute("CREATE EXTENSION IF NOT EXISTS unaccent")
  end

  def down do
    execute("DROP EXTENSION IF EXISTS unaccent")
    execute("DROP EXTENSION IF EXISTS pg_trgm")
    execute("DROP EXTENSION IF EXISTS vector")
  end
end
