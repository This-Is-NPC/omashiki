defmodule OmashikiWeb.Api.DiscoveryController do
  use OmashikiWeb.Api.Controller

  alias Omashiki.Config
  alias OmashikiWeb.ApiSpec.Schemas

  tags ["discovery"]

  operation :repositories,
    summary: "List registered repositories",
    security: [%{"bearer" => ["read"]}],
    responses: %{200 => {"Repositories", "application/json", Schemas.RepositoryListResponse}}

  def repositories(conn, _params) do
    json(conn, %{data: Enum.map(Config.repositories(), &repository_json/1)})
  end

  operation :environments,
    summary: "List registered environments",
    security: [%{"bearer" => ["read"]}],
    responses: %{200 => {"Environments", "application/json", Schemas.EnvironmentListResponse}}

  def environments(conn, _params) do
    json(conn, %{data: Enum.map(Config.environments(), &environment_json/1)})
  end

  defp repository_json(repository) do
    %{name: repository.name, base_branch: repository.base_branch}
  end

  defp environment_json(environment) do
    profile = environment.preset

    %{
      name: environment.name,
      preset: environment.preset.name,
      plugin: profile.plugin,
      runtime: environment.runtime.name,
      handler: environment.runtime.handler,
      backend: environment.runtime.backend,
      distribution: environment.runtime.distribution,
      image: environment.runtime.image,
      timeout_ms: environment.timeout_ms,
      network: environment.network,
      capabilities: environment.capabilities,
      resources: environment.resources
    }
  end
end
