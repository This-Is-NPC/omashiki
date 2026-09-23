defmodule Omashiki.Doctor do
  @moduledoc """
  Diagnoses the installation before a job finds the problem the slow way.

  Each check is `%{id, status, summary, fix}`: `status` is `:ok`, `:warn` or
  `:error`, and `fix` tells the operator what to do (nil when nothing is). The
  doctor decides what to check and what an answer means; every observation of
  the host goes through an `Omashiki.Doctor.Probe`.

  The route check starts a container, so it runs only when asked (`route:
  true`): at boot and from `Omashiki.Cli.Doctor`. Every other check is cheap
  enough to repeat.

  A fix names the commands of the install that runs the house: the `mise`
  tasks in a checkout, `docker` and `bin/doctor` in a release.
  """

  alias Omashiki.Config
  alias Omashiki.Runtime.{ContainerManager, HouseUrl}
  alias Omashiki.Runtimes

  @type status :: :ok | :warn | :error
  @type check :: %{id: String.t(), status: status(), summary: String.t(), fix: String.t() | nil}

  @doc """
  Run the checks. Options:

    * `:probe` — an `Omashiki.Doctor.Probe`; defaults to `:doctor_probe`, else
      `Omashiki.Doctor.HostProbe`
    * `:route` — also check that containers and the house reach each other
      (default false)
    * `:environments`, `:host_credentials`, `:identities` — default to the
      live configuration
    * `:port` — the house HTTP port; defaults to the endpoint's
    * `:house_url` — where containers reach the house; defaults to
      `Omashiki.Runtime.HouseUrl.base_url/0`
    * `:install` — `:checkout` or `:release`, which commands a fix names;
      defaults to the `:install` the runtime configuration resolved
  """
  @spec run(keyword()) :: [check()]
  def run(opts \\ []) do
    probe =
      Keyword.get_lazy(opts, :probe, fn ->
        Application.get_env(:omashiki, :doctor_probe, Omashiki.Doctor.HostProbe)
      end)

    environments = Keyword.get_lazy(opts, :environments, &Config.environments/0)
    host_credentials = Keyword.get_lazy(opts, :host_credentials, &Config.host_credentials/0)
    identities = Keyword.get_lazy(opts, :identities, &Config.identities/0)

    opts =
      Keyword.put_new_lazy(opts, :install, fn -> Application.fetch_env!(:omashiki, :install) end)

    docker_checks(probe, environments, opts) ++
      host_credential_checks(probe, host_credentials, environments, opts[:install]) ++
      identity_checks(probe, identities)
  end

  @doc "The worst status among `checks`."
  @spec worst([check()]) :: status()
  def worst(checks) do
    statuses = Enum.map(checks, & &1.status)

    cond do
      :error in statuses -> :error
      :warn in statuses -> :warn
      true -> :ok
    end
  end

  defp docker_checks(probe, environments, opts) do
    case probe.runtime() do
      :ok ->
        images = images(probe, environments)
        networks = networks(probe, environments)

        routes =
          if Keyword.get(opts, :route, false),
            do: route_checks(probe, environments, images, networks, opts),
            else: []

        [ok("docker", "Docker answers.")] ++
          image_checks(images, opts[:install]) ++
          network_checks(environments, networks, opts[:install]) ++ routes

      {:error, reason} ->
        [
          error(
            "docker",
            "Docker does not answer (#{inspect(reason)}). Image, network, and route checks were skipped.",
            "Start Docker and check that this account can use its socket."
          )
        ]
    end
  end

  # image => {probe result, environment names using it}
  defp images(probe, environments) do
    environments
    |> Enum.filter(&image_of/1)
    |> Enum.group_by(&image_of/1, & &1.name)
    |> Map.new(fn {image, names} -> {image, {probe.image(image), Enum.sort(names)}} end)
  end

  defp image_checks(images, install) do
    images
    |> Enum.sort()
    |> Enum.map(fn {image, {result, names}} ->
      id = "image:#{image}"

      case result do
        :ok ->
          ok(id, "Image #{image} is present.")

        {:error, :not_found} ->
          error(
            id,
            "Image #{image} is missing, so #{names(names)} cannot start.",
            Runtimes.provide_image(image, install)
          )

        {:error, reason} ->
          error(
            id,
            "Image #{image} could not be inspected (#{inspect(reason)}).",
            "Check the Docker daemon, then run the doctor again."
          )
      end
    end)
  end

  # Resolved Docker network => probe result, for every restricted environment.
  defp networks(probe, environments) do
    environments
    |> Enum.filter(&restricted?/1)
    |> Enum.map(&ContainerManager.network_mode/1)
    |> Enum.reject(&(&1 in ["none", "host"]))
    |> Enum.uniq()
    |> Map.new(&{&1, probe.network(&1)})
  end

  defp network_checks(environments, networks, install) do
    for environment <- Enum.sort_by(environments, & &1.name), restricted?(environment) do
      id = "network:#{environment.name}"
      name = environment.name

      case ContainerManager.network_mode(environment) do
        "none" ->
          error(
            id,
            "Environment #{name} is restricted but has no agent network. " <>
              "Its jobs fail with harness_unreachable_no_network.",
            agent_network_fix(install)
          )

        "host" ->
          ok(id, "Environment #{name} runs on the host network.")

        network ->
          case Map.fetch!(networks, network) do
            :ok ->
              ok(id, "Environment #{name} runs on network #{network}.")

            {:error, :not_found} ->
              error(
                id,
                "Environment #{name} uses network #{network}, which does not exist.",
                "Create it with `docker network create #{network}`, or set " <>
                  "OMASHIKI_AGENT_NETWORK_MODE to an existing network."
              )

            {:error, reason} ->
              error(
                id,
                "Network #{network} of environment #{name} could not be inspected (#{inspect(reason)}).",
                "Check the Docker daemon, then run the doctor again."
              )
          end
      end
    end
  end

  defp route_checks(probe, environments, images, networks, opts) do
    networks = for {network, :ok} <- Enum.sort(networks), do: network
    port = house_port(opts)

    if networks == [] do
      []
    else
      house = probe.house(port)
      url = Keyword.get_lazy(opts, :house_url, &HouseUrl.base_url/0)

      Enum.map(networks, fn network ->
        image = probe_image(network, environments, images)
        route_check(probe, network, house, image, {port, url}, opts[:install])
      end)
    end
  end

  defp route_check(_probe, network, {:error, _reason}, _image, {port, _url}, install) do
    warn(
      "route:#{network}",
      "The house does not answer on port #{port}, so the route from network #{network} was not checked.",
      start_fix(install)
    )
  end

  defp route_check(_probe, network, :ok, nil, _house, _install) do
    warn(
      "route:#{network}",
      "No agent image is present to check the route from network #{network}.",
      "Build or pull the missing images the image checks name, then run the doctor again."
    )
  end

  defp route_check(probe, network, :ok, image, {_port, url}, _install) do
    id = "route:#{network}"

    case probe.route(image, network, String.trim_trailing(url, "/") <> "/api/v1/health") do
      :ok ->
        ok(
          id,
          "Containers on network #{network} reach the house at #{url}, and the house reaches them."
        )

      {:error, :no_python} ->
        warn(
          id,
          "Image #{image} has no python3, so the route between the house and network #{network} was not checked.",
          "Run the doctor with an agent image that ships python3."
        )

      {:error, {:blocked, blocked}} ->
        error(
          id,
          Enum.map_join(blocked, " ", &blocked_summary(&1, network, url)),
          Enum.map_join(blocked, " ", &blocked_fix(&1, network, url))
        )

      {:error, reason} ->
        error(
          id,
          "The route between the house and network #{network} could not be checked (#{inspect(reason)}).",
          "Check the Docker daemon, then run the doctor again."
        )
    end
  end

  defp blocked_summary({:to_house, reason}, network, url),
    do:
      "Containers on network #{network} cannot reach the house at #{url} (#{inspect(reason)}). " <>
        "Agents would run until their timeout without tools."

  defp blocked_summary({:from_house, reason}, network, _url),
    do:
      "The house cannot reach containers on network #{network} (#{inspect(reason)}). " <>
        "Jobs would fail with harness_not_ready."

  defp blocked_fix({:to_house, _reason}, network, url) do
    case URI.parse(url) do
      %URI{host: "host.docker.internal", port: port} ->
        "Allow the agent network to reach port #{port} on the host. A host firewall " <>
          "such as ufw can block it, for example: " <>
          "`sudo ufw allow from 172.16.0.0/12 to any port #{port} proto tcp`. " <>
          "`[app].host` must not be 127.0.0.1."

      _uri ->
        "Set OMASHIKI_HOUSE_URL to the address of the house on network #{network}."
    end
  end

  defp blocked_fix({:from_house, _reason}, network, _url),
    do:
      "Attach the house container to network #{network}, or set " <>
        "OMASHIKI_AGENT_NETWORK_MODE to a network it is attached to, and restart the house."

  # An image already present locally: one the network's own environments use
  # first, then any. The doctor never pulls.
  defp probe_image(network, environments, images) do
    present = for {image, {:ok, _names}} <- Enum.sort(images), do: image

    own =
      environments
      |> Enum.filter(&(restricted?(&1) and ContainerManager.network_mode(&1) == network))
      |> Enum.map(&image_of/1)

    Enum.find(present, &(&1 in own)) || List.first(present)
  end

  defp agent_network_fix(:checkout),
    do:
      "Set OMASHIKI_AGENT_NETWORK_MODE to a Docker network, such as `bridge` " <>
        "on a single machine, and restart the house."

  defp agent_network_fix(:release),
    do:
      "Set OMASHIKI_AGENT_NETWORK_MODE to a Docker network the house container " <>
        "is attached to, and restart the house."

  defp start_fix(:checkout),
    do: "Start the house with `mise run up`, then run `mise run doctor` again."

  defp start_fix(:release),
    do: "Start the house, for example with `docker compose up -d`, then run `bin/doctor` again."

  defp host_credential_checks(probe, host_credentials, environments, install) do
    in_use =
      environments
      |> Enum.flat_map(&Map.get(&1, :host_credentials, []))
      |> MapSet.new(& &1.name)

    Enum.map(host_credentials, fn credential ->
      id = "host-credential:#{credential.name}"

      unreadable =
        for {file, origin} <- Enum.sort(credential.files), probe.readable(origin) != :ok, do: file

      cond do
        unreadable == [] ->
          ok(id, "Host credential #{credential.name} is readable.")

        MapSet.member?(in_use, credential.name) ->
          error(
            id,
            "Host credential #{credential.name} cannot read its origin for " <>
              "#{Enum.join(unreadable, ", ")}. Jobs using it fail with host_credential_unavailable.",
            host_credential_fix(credential, install)
          )

        true ->
          warn(
            id,
            "Host credential #{credential.name} cannot read its origin for " <>
              "#{Enum.join(unreadable, ", ")}. No environment uses it yet.",
            host_credential_fix(credential, install)
          )
      end
    end)
  end

  defp host_credential_fix(credential, :checkout) do
    "Log in with #{credential.kind} on this machine, or correct " <>
      "[host_credentials.#{credential.name}] in omashiki.toml."
  end

  defp host_credential_fix(credential, :release) do
    "Mount the directory of each origin read-only into the house container, then " <>
      "restart the house (see https://github.com/This-Is-NPC/omashiki/blob/" <>
      "v#{Application.spec(:omashiki, :vsn)}/docs/how-to-configure-model-access.md" <>
      "#mount-the-origins-into-a-container). If an origin is missing on this machine " <>
      "too, log in with #{credential.kind} first. Or correct " <>
      "[host_credentials.#{credential.name}] in omashiki.toml."
  end

  defp identity_checks(probe, identities) do
    Enum.map(identities, fn identity ->
      id = "identity:#{identity.name}"

      case probe.identity(identity) do
        :ok ->
          ok(id, "Identity #{identity.name} mints an installation token.")

        {:error, reason} ->
          error(
            id,
            "Identity #{identity.name} cannot mint an installation token (#{inspect(reason)}).",
            "Check app_id, installation_id, and the private key of " <>
              "[identities.#{identity.name}], and that the App is installed."
          )
      end
    end)
  end

  defp restricted?(environment), do: Map.get(environment, :network) == "restricted"

  defp image_of(%{runtime: %{image: image}}) when is_binary(image), do: image
  defp image_of(_environment), do: nil

  defp house_port(opts) do
    Keyword.get_lazy(opts, :port, fn ->
      :omashiki
      |> Application.get_env(OmashikiWeb.Endpoint, [])
      |> Keyword.get(:http, [])
      |> Keyword.get(:port, 4000)
    end)
  end

  defp names([name]), do: "environment #{name}"
  defp names(names), do: "environments #{Enum.join(names, ", ")}"

  defp ok(id, summary), do: %{id: id, status: :ok, summary: summary, fix: nil}
  defp warn(id, summary, fix), do: %{id: id, status: :warn, summary: summary, fix: fix}
  defp error(id, summary, fix), do: %{id: id, status: :error, summary: summary, fix: fix}
end
