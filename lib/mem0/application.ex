defmodule Mem0.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Mem0Web.Telemetry,
      {DNSCluster, query: Application.get_env(:mem0, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Mem0.PubSub},
      # Start to serve requests, typically the last entry
      Mem0Web.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Mem0.Supervisor]
    Supervisor.start_link(repo_children() ++ children, opts)
  end

  # `mix test.core` sets this to `false`: the functional core's suite touches no
  # database, and a connection pool retrying against a stopped container fills
  # an otherwise-passing run with red. Everything else leaves it alone and gets
  # the Repo, so this cannot silently disable persistence in dev or prod.
  @spec repo_children() :: [module()]
  defp repo_children do
    if Application.get_env(:mem0, :start_repo, true), do: [Mem0.Repo], else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    Mem0Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
