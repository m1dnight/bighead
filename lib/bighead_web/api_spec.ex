defmodule BigheadWeb.ApiSpec do
  @moduledoc """
  The OpenAPI document for the API, assembled from the operations each
  controller defines next to itself (`*_api_spec.ex` in the controller's
  folder). Served as JSON at `/v1/openapi`.
  """

  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.Info
  alias OpenApiSpex.OpenApi
  alias OpenApiSpex.Paths
  alias OpenApiSpex.Server

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      servers: [Server.from_endpoint(BigheadWeb.Endpoint)],
      info: %Info{title: "Bighead", version: "1.0.0"},
      paths: Paths.from_router(BigheadWeb.Router)
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
