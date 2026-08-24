defmodule Omashiki.HostSettings do
  @moduledoc """
  Host resource limits from `omashiki.toml` `[limits]`.

  Changing the file requires a restart — no live UI mutation.
  """

  alias Omashiki.Config

  @default_limits %{
    pids_limit: 256,
    memory_bytes: 2 * 1024 * 1024 * 1024,
    memory_swap_bytes: 2 * 1024 * 1024 * 1024,
    nano_cpus: 2_000_000_000
  }

  @limit_keys ~w(pids_limit memory_bytes memory_swap_bytes nano_cpus)a

  def default_limits, do: @default_limits

  def get_limits do
    toml = Config.limits()

    @default_limits
    |> Map.merge(Map.take(toml, @limit_keys))
  end

  def get_max_concurrent_containers do
    case Config.limits() do
      %{max_concurrent_containers: n} when is_integer(n) and n > 0 -> n
      _ -> Application.get_env(:omashiki, :max_concurrent_containers, 8)
    end
  end

  @doc "Rejected — limits are declared in TOML; edit the file and restart."
  def update(_attrs), do: {:error, :toml_source}
end
