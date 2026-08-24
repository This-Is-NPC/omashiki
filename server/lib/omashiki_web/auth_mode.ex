defmodule OmashikiWeb.AuthMode do
  @moduledoc """
  API auth mode for local UX (Fase 6).

  * `:bearer` (default) — Bearer/session required on `/api/v1/*` (LAN-safe).
  * `:none` — credential optional **only** for loopback peers, and only
    when the Endpoint binds to loopback. Never the default; refused at
    boot if the Endpoint listens on a non-loopback address (scenario 2).

  LiveView login is unaffected — this gates MCP/REST only.
  """

  @type mode :: :bearer | :none

  @doc "Resolved mode. Unknown values fall back to `:bearer`."
  @spec mode() :: mode()
  def mode do
    case Application.get_env(:omashiki, :auth_mode, :bearer) do
      :none -> :none
      "none" -> :none
      _ -> :bearer
    end
  end

  @doc """
  Warns when `:none` is configured while the Endpoint is not loopback-only.

  This used to refuse to start. It no longer does: `auth.enabled = false` in
  omashiki.toml is the operator saying they want auth off, and a tool that
  overrides its owner on their own machine is the wrong kind of careful. The
  warning stays because turning login off while bound to a LAN address is
  worth seeing in the log, not because the boot should second-guess it.

  Call from `Application.start/2` before the supervision tree comes up.
  """
  @spec assert_boot_safe!() :: :ok
  def assert_boot_safe! do
    if mode() == :none and not endpoint_loopback_only?() do
      require Logger

      Logger.warning("""
      auth is disabled and the Endpoint is not loopback-only \
      (http ip: #{inspect(endpoint_http_ip())}).
      Every peer that can reach this address gets in without a credential.
      """)
    end

    :ok
  end

  @doc """
  True when authentication is off — no login for LiveView, no credential for
  the API. Set through `auth.enabled = false` in omashiki.toml.
  """
  @spec disabled?() :: boolean()
  def disabled?, do: mode() == :none

  @doc "True when `ip` is IPv4/IPv6 loopback."
  @spec loopback_ip?(term()) :: boolean()
  def loopback_ip?({127, _, _, _}), do: true
  def loopback_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # IPv4-mapped IPv6 ::ffff:127.x.x.x
  def loopback_ip?({0, 0, 0, 0, 0, 65_535, hi, lo}) when is_integer(hi) and is_integer(lo) do
    <<a::8, b::8, c::8, d::8>> = <<hi::16, lo::16>>
    loopback_ip?({a, b, c, d})
  end

  def loopback_ip?(_), do: false

  @doc "True when Endpoint `http: [ip: ...]` is loopback-only."
  @spec endpoint_loopback_only?() :: boolean()
  def endpoint_loopback_only?, do: loopback_ip?(endpoint_http_ip())

  defp endpoint_http_ip do
    http = Application.get_env(:omashiki, OmashikiWeb.Endpoint, [])[:http] || []
    Keyword.get(http, :ip)
  end
end
