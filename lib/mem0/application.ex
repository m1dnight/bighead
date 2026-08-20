defmodule Mem0.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Mem0Web.Telemetry,
      Mem0.Repo,
      {DNSCluster, query: Application.get_env(:mem0, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Mem0.PubSub},
      # Start a worker by calling: Mem0.Worker.start_link(arg)
      # {Mem0.Worker, arg},
      # Start to serve requests, typically the last entry
      Mem0Web.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Mem0.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    Mem0Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
