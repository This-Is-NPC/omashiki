defmodule OmashikiWeb.Api.DiscoveryController do
  use OmashikiWeb, :controller

  alias Omashiki.Config

  def repositories(conn, _params) do
    json(conn, %{data: Enum.map(Config.repositories(), &repository_json/1)})
  end

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
      isolation: profile.isolation.kind,
      timeout_ms: environment.timeout_ms,
      network: environment.network,
      capabilities: environment.capabilities,
      resources: environment.resources
    }
  end
end
