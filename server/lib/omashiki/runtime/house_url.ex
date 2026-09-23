defmodule Omashiki.Runtime.HouseUrl do
  @moduledoc """
  The base URL agent containers use to reach the house: the LLM gateway, the
  tools proxy, the package proxy, and the doctor's route check all start here.

  `OMASHIKI_HOUSE_URL` (`:house_url`) names it when the house shares a Docker
  network with its agents, as `deploy/compose.yml` does. Without it, agents
  reach the house through the host on the endpoint port: at the loopback on the
  host network, at `host.docker.internal` on any other.
  """

  @spec base_url() :: String.t()
  def base_url do
    Application.get_env(:omashiki, :house_url) || through_host()
  end

  defp through_host do
    port =
      :omashiki
      |> Application.get_env(OmashikiWeb.Endpoint, [])
      |> Keyword.get(:http, [])
      |> Keyword.get(:port, 4000)

    host =
      if Application.get_env(:omashiki, :agent_network_mode) == "host",
        do: "127.0.0.1",
        else: "host.docker.internal"

    "http://#{host}:#{port}"
  end
end
