defmodule Omashiki.Doctor.HostProbe do
  @moduledoc """
  `Omashiki.Doctor.Probe` against the real host: the Docker socket the
  container manager uses, the house endpoint, host files, and GitHub.

  Docker calls consume the caller's mailbox while in flight (see
  `Omashiki.Runtime.ContainerManager`), so run this from a dedicated process.
  """

  @behaviour Omashiki.Doctor.Probe

  alias Omashiki.Identities.GithubApp
  alias Omashiki.Identities.Http
  alias Omashiki.Runtime.ContainerManager
  alias Omashiki.Runtime.HostCredentials

  # Exit status the probe script uses when the image has no HTTP client.
  @no_http_client 127

  # `$1` is the URL. curl first; python3 covers the images that ship no curl.
  @route_script """
  if command -v curl >/dev/null 2>&1; then exec curl -fsS -m 5 -o /dev/null "$1"; fi
  if command -v python3 >/dev/null 2>&1; then
    exec python3 -c 'import sys, urllib.request; urllib.request.urlopen(sys.argv[1], timeout=5)' "$1"
  fi
  exit 127
  """

  @impl true
  def runtime, do: ContainerManager.docker_ping()

  @impl true
  def image(image), do: found(ContainerManager.docker_get("/images/#{image}/json"))

  @impl true
  def network(name),
    do: found(ContainerManager.docker_get("/networks/#{URI.encode_www_form(name)}"))

  @impl true
  def house(port) do
    case Http.request(:get, "http://127.0.0.1:#{port}/api/v1/health", [], nil) do
      {:ok, 200, _body} -> :ok
      {:ok, status, _body} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def route(image, network, url) do
    config = %{
      "Image" => image,
      "Entrypoint" => ["sh", "-c"],
      "Cmd" => [@route_script, "omashiki-doctor", url],
      "HostConfig" => %{
        "NetworkMode" => network,
        "ExtraHosts" => ["host.docker.internal:host-gateway"]
      }
    }

    name = "omashiki-doctor-#{System.unique_integer([:positive])}"

    # The Engine API never pulls on create: a missing image is `:not_found`.

    case ContainerManager.docker_post("/containers/create?name=#{name}", config) do
      {:ok, %{"Id" => id}} ->
        try do
          with :ok <- ContainerManager.docker_post_no_body("/containers/#{id}/start"),
               {:ok, %{"StatusCode" => code}} <-
                 ContainerManager.docker_post("/containers/#{id}/wait", %{}) do
            case code do
              0 -> :ok
              @no_http_client -> {:error, :no_http_client}
              code -> {:error, {:exit, code}}
            end
          end
        after
          ContainerManager.docker_delete("/containers/#{id}?force=true")
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @impl true
  def readable(origin), do: HostCredentials.readable(origin)

  @impl true
  def identity(identity) do
    case GithubApp.installation_token(identity) do
      {:ok, _token} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp found({:ok, _payload}), do: :ok
  defp found({:error, reason}), do: {:error, reason}
end
