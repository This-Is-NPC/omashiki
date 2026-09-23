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

  # The port the probe container listens on for the house.
  @listen_port 7000
  # How long the house tries to reach the probe container; the container
  # listens a little longer, then fetches the house.
  @reach_ms 8_000

  # Exit status the probe script uses when the image has no python3.
  @no_python 127

  # `$1` is the house URL, `$2` the port to listen on. The container first
  # waits for the house to connect, then fetches the house, and exits non-zero
  # when that fails.
  @route_script """
  command -v python3 >/dev/null 2>&1 || exit 127
  exec python3 -c '
  import socket, sys, urllib.request
  server = socket.create_server(("", int(sys.argv[2])))
  server.settimeout(10)
  try:
      server.accept()[0].close()
  except OSError:
      pass
  try:
      urllib.request.urlopen(sys.argv[1], timeout=5)
  except Exception:
      sys.exit(3)
  ' "$1" "$2"
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
      "Cmd" => [@route_script, "omashiki-doctor", url, Integer.to_string(@listen_port)],
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
          with :ok <- ContainerManager.docker_post_no_body("/containers/#{id}/start") do
            from_house = reach(id, network)

            case ContainerManager.docker_post("/containers/#{id}/wait", %{}) do
              {:ok, %{"StatusCode" => @no_python}} -> {:error, :no_python}
              {:ok, %{"StatusCode" => code}} -> directions(code, from_house)
              {:error, reason} -> {:error, reason}
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

  # The house reaches the probe container the way it reaches a harness.
  defp reach(id, network) do
    case ContainerManager.harness_endpoint(id, nil, @listen_port, network) do
      {:ok, {address, port}} -> connect(address, port, deadline(@reach_ms))
      {:error, reason} -> {:error, reason}
    end
  end

  defp connect(address, port, deadline) do
    case :gen_tcp.connect(String.to_charlist(address), port, [], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(200)
          connect(address, port, deadline)
        else
          {:error, reason}
        end
    end
  end

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

  defp directions(code, from_house) do
    to_house = if code == 0, do: :ok, else: {:error, {:exit, code}}

    blocked =
      for {direction, {:error, reason}} <- [to_house: to_house, from_house: from_house],
          do: {direction, reason}

    if blocked == [], do: :ok, else: {:error, {:blocked, blocked}}
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
