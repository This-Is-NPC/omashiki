defmodule Omashiki.Jobs.SecretScan.Policy do
  @moduledoc """
  How the secret scan treats one job's output: the house key its findings'
  fingerprints are made with, and the fingerprints allowed for its
  environment (and repository, for a git sink).

  The house builds it at dispatch (`Omashiki.Jobs.SecretAllowances.policy/1`)
  and sends it with the offer, so a worker scans without a database. The key
  is never inspected or logged.
  """

  @derive {Inspect, except: [:key]}
  @enforce_keys [:key, :allowed]
  defstruct @enforce_keys

  @type t :: %__MODULE__{key: binary(), allowed: [String.t()]}

  @doc "True when the policy allows `fingerprint`."
  def allowed?(%__MODULE__{allowed: allowed}, fingerprint), do: fingerprint in allowed

  @doc "Encode for the offer."
  def to_map(%__MODULE__{} = policy),
    do: %{"key" => Base.encode64(policy.key), "allowed" => policy.allowed}

  @doc "Decode from the offer."
  def from_map(%{"key" => key, "allowed" => allowed}) when is_list(allowed) do
    case Base.decode64(key) do
      {:ok, key} when byte_size(key) == 32 ->
        if Enum.all?(allowed, &is_binary/1),
          do: {:ok, %__MODULE__{key: key, allowed: allowed}},
          else: {:error, :invalid_secret_scan}

      _ ->
        {:error, :invalid_secret_scan}
    end
  end

  def from_map(_map), do: {:error, :invalid_secret_scan}
end
