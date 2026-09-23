defmodule Omashiki.Jobs.SecretAllowances do
  @moduledoc """
  Findings an operator allowed, so that the secret scan stops refusing them.

  An allowance names a finding by its fingerprint, which binds the file, the
  gitleaks rule and the secret. It applies to later jobs of the same
  environment and, for a git sink, of the same repository. The same secret in
  another file, or another secret in the same file, is still refused.

  Fingerprints are HMAC-SHA256 values keyed with the house key, derived from
  `SECRET_KEY_BASE` with a dedicated salt. A new `SECRET_KEY_BASE` changes
  every fingerprint, so existing allowances stop matching.

  Allowances are house policy, managed from the Home task details and the
  Config screen by operators; the public API does not expose them.
  """

  import Ecto.Query

  alias Omashiki.Accounts.User
  alias Omashiki.Jobs.{Job, SecretAllowance}
  alias Omashiki.Jobs.SecretScan.Policy
  alias Omashiki.Repo

  @salt "omashiki.secret_scan.fingerprint"

  @doc "The secret-scan policy of `job`: the house key and the allowed fingerprints."
  @spec policy(Job.t()) :: Policy.t()
  def policy(%Job{} = job),
    do: %Policy{key: house_key(), allowed: fingerprints(job.environment, job.repository)}

  @doc "Every allowance, newest first, with who created it."
  def list do
    from(a in SecretAllowance, order_by: [desc: a.inserted_at, desc: a.id], preload: :created_by)
    |> Repo.all()
  end

  @doc "Fingerprints allowed for an environment and repository (nil for files and none)."
  def fingerprints(environment, repository) do
    environment
    |> scoped(repository)
    |> select([a], a.fingerprint)
    |> Repo.all()
  end

  @doc """
  Allow the finding of `job`'s held output that has `fingerprint`, in the
  job's environment and repository. Allowing it again returns the existing
  allowance.
  """
  def allow(%Job{review: %{"error" => error}} = job, fingerprint, %User{} = user, note)
      when is_binary(fingerprint) do
    findings = get_in(error, ["details", "findings"]) || []

    with %{} = finding <- Enum.find(findings, &(&1["fingerprint"] == fingerprint)) || :unknown,
         nil <-
           job.environment
           |> scoped(job.repository)
           |> where([a], a.fingerprint == ^fingerprint)
           |> Repo.one() do
      %SecretAllowance{}
      |> SecretAllowance.changeset(%{
        fingerprint: fingerprint,
        environment: job.environment,
        repository: job.repository,
        file: finding["file"],
        rule_id: finding["rule_id"],
        note: present(note),
        created_by_id: user.id
      })
      |> Repo.insert()
    else
      :unknown -> {:error, :unknown_finding}
      %SecretAllowance{} = allowance -> {:ok, allowance}
    end
  end

  def allow(%Job{}, _fingerprint, _user, _note), do: {:error, :unknown_finding}

  @doc "Remove an allowance: its finding is refused again."
  def delete(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %SecretAllowance{} = allowance <- Repo.get(SecretAllowance, id) do
      Repo.delete(allowance)
    else
      _ -> {:error, :not_found}
    end
  end

  # The house key for fingerprints. Only the house derives it; a worker gets
  # it with each offer.
  defp house_key do
    secret_key_base =
      Application.fetch_env!(:omashiki, OmashikiWeb.Endpoint)[:secret_key_base] ||
        raise "OmashikiWeb.Endpoint :secret_key_base is not configured"

    Plug.Crypto.KeyGenerator.generate(secret_key_base, @salt, length: 32)
  end

  defp scoped(environment, repository) do
    from(a in SecretAllowance,
      where: a.environment == ^environment,
      where: fragment("? IS NOT DISTINCT FROM ?", a.repository, ^repository)
    )
  end

  defp present(note) when is_binary(note) do
    case String.trim(note) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_note), do: nil
end
