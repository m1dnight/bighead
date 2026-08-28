defmodule Mem0.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :mem0

  @spec migrate() :: [{:ok, term(), term()}]
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @spec rollback(module(), integer()) :: {:ok, term(), term()}
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @spec repos() :: [module()]
  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  @spec load_app() :: {:ok, [atom()]} | {:error, term()}
  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
