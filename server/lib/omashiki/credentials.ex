defmodule Omashiki.Credentials do
  @moduledoc """
  LLM credentials from `omashiki.toml` via `Omashiki.Config`.

  Identity is the credential **name**. Gateway tokens carry that name.

  ## Live lookup versus admitted lookup

  `get_credential/1` reads the **live** generation. That is right for anything
  deciding what to do next — listing, provisioning a job admitted a moment ago
  — and wrong for work already in flight, because `Config.reload/1` can replace
  the model under a running attempt without a restart.

  `pin/1` and `admitted/2` read the credential the job was *admitted* with,
  from its own `environment_snapshot`. Everything the gateway needs to route a
  turn — provider, model, base URL, aliases, fallback chain — was captured
  there at admission, so an attempt keeps talking to the model it started on
  even after the operator swaps it.

  The one field that cannot be pinned is `api_key`: admission strips it, on
  purpose, so a live key never lands in a database column. It is therefore
  taken from the live generation by name. Rotating a key applies immediately
  to running attempts, which is the behaviour a rotation wants. Deleting the
  credential outright leaves an in-flight attempt with no key, and it fails at
  the upstream rather than silently running against someone else's account.
  """

  alias Omashiki.Config
  alias Omashiki.Credentials.Credential

  def list_credentials, do: Config.credentials()

  def get_credential!(name) when is_binary(name) do
    case get_credential(name) do
      nil -> raise Ecto.NoResultsError, queryable: "credentials"
      cred -> cred
    end
  end

  def get_credential(nil), do: nil
  def get_credential(name) when is_binary(name), do: Config.get_credential(name)

  def get_by_name(name) when is_binary(name), do: get_credential(name)

  @doc """
  The credential named `name` as the job was admitted with it.

  Falls back to the live generation when the snapshot does not carry the name —
  a job admitted before the environment declared it, or a fixture with a bare
  snapshot.
  """
  def admitted(environment_snapshot, name)
      when is_map(environment_snapshot) and is_binary(name) do
    environment_snapshot
    |> Map.get(:credentials, Map.get(environment_snapshot, "credentials", []))
    |> List.wrap()
    |> Enum.find(&(entry_name(&1) == name))
    |> case do
      nil -> get_credential(name)
      entry -> pin(entry)
    end
  end

  def admitted(_environment_snapshot, name) when is_binary(name), do: get_credential(name)
  def admitted(_environment_snapshot, _name), do: nil

  @doc """
  Turn one captured `environment_snapshot` credential entry into a `Credential`.

  A `%Credential{}` is already live and returned unchanged. A captured map is
  rebuilt from what it captured, with `api_key` filled in from the live
  generation by name.

  An entry that carries only a name is a *reference*, not a capture — nothing
  was pinned, so there is nothing to pin to and the live generation answers.
  `Jobs.Admission` always captures the whole expanded credential, so this is
  the shape of a hand-built or pre-capture snapshot, never of an admitted job.
  """
  def pin(%Credential{} = credential), do: credential

  def pin(entry) when is_map(entry) do
    case {entry_name(entry), field(entry, :model, "model")} do
      {nil, _model} ->
        nil

      {name, model} when is_binary(model) and model != "" ->
        %Credential{
          name: name,
          provider: field(entry, :provider, "provider"),
          model: model,
          base_url: field(entry, :base_url, "base_url"),
          api_key: live_api_key(name),
          fallback_chain: List.wrap(field(entry, :fallback_chain, "fallback_chain") || []),
          model_aliases: field(entry, :model_aliases, "model_aliases") || %{}
        }

      {name, _model} ->
        get_credential(name)
    end
  end

  def pin(_entry), do: nil

  defp entry_name(entry) do
    case field(entry, :name, "name") do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  # Snapshots read back from the database are string-keyed; a value taken
  # straight off `Omashiki.Config` is atom-keyed. Both reach here.
  defp field(entry, atom_key, string_key) do
    case Map.get(entry, atom_key) do
      nil -> Map.get(entry, string_key)
      value -> value
    end
  end

  defp live_api_key(name) do
    case get_credential(name) do
      %Credential{api_key: api_key} -> api_key
      _ -> nil
    end
  end

  @doc """
  Masked representation of the key for list views.
  """
  def masked_key(%Credential{api_key: nil}), do: "****"
  def masked_key(%Credential{api_key: key}) when is_binary(key) and byte_size(key) < 8, do: "****"

  def masked_key(%Credential{api_key: key}) when is_binary(key),
    do: "****" <> binary_part(key, byte_size(key) - 4, 4)

  def masked_key(%Credential{}), do: "****"
end
