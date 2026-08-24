defmodule Omashiki.Runtimes.CacheGroup do
  @moduledoc """
  Host-backed cache shared by sandbox containers.

  Cache groups are declared in `omashiki.toml`; only runtime state belongs in
  the database. The container destination is derived from `name` and is always
  `/omashiki-cache/<name>`.
  """

  use Ecto.Schema

  @primary_key false

  embedded_schema do
    field(:name, :string)
    field(:host, :string)
    field(:env, :map, default: %{})
    field(:max_size_mb, :integer)
    field(:policy, :map)
  end

  @doc "Host directory for payloads under this group's policy partition."
  def host_path(%__MODULE__{host: host, policy: policy}) when is_binary(host) do
    case policy do
      %Omashiki.SupplyChain.Policy{digest: digest} when is_binary(digest) ->
        Path.join(host, "policy-" <> digest)

      %Omashiki.SupplyChain.Policy{} = policy ->
        Path.join(host, "policy-" <> Omashiki.SupplyChain.Policy.digest(policy))

      _ ->
        host
    end
  end

  def host_path(%__MODULE__{host: host}), do: host
end
