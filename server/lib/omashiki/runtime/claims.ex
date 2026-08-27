defmodule Omashiki.Runtime.Claims do
  @moduledoc "Short-lived, job-scoped authorization for the runtime data plane."

  alias Omashiki.Config
  alias Omashiki.Jobs.Job
  alias Omashiki.Repo

  @max_age_seconds 15 * 60
  @active_statuses ~w(queued provisioning running)
  @kinds ~w(gateway tools supply_chain egress)

  @doc "Mint a signed claim set from the persisted job snapshot."
  def issue(kind, job, attrs \\ %{})

  def issue(kind, %Job{} = job, attrs) when kind in @kinds and is_map(attrs) do
    attrs = stringify(attrs)

    with :ok <- valid_job(job),
         :ok <- required_attributes(kind, attrs) do
      claims =
        attrs
        |> Map.merge(%{
          "kind" => kind,
          "job_id" => job.id,
          "token_owner" => job.user_id,
          "admitted_environment_digest" => job.admitted_environment_digest,
          "issued_at" => DateTime.utc_now(:second) |> DateTime.to_unix()
        })

      {:ok, Phoenix.Token.sign(OmashikiWeb.Endpoint, salt(kind), claims)}
    end
  end

  def issue(_, _, _), do: {:error, :invalid_runtime_job}

  @doc "Verify a token's signature, kind, shape, and short lifetime."
  def verify(kind, token) when kind in @kinds and is_binary(token) do
    with {:ok, claims} <-
           Phoenix.Token.verify(OmashikiWeb.Endpoint, salt(kind), token,
             max_age: @max_age_seconds
           ),
         :ok <- validate_claims(kind, claims) do
      {:ok, claims}
    else
      {:error, :expired} -> {:error, :expired}
      {:error, _} -> {:error, :invalid}
      _ -> {:error, :invalid}
    end
  end

  def verify(_, _), do: {:error, :invalid}

  @doc "Authorize already verified claims against the current immutable job row."
  def authorize(kind, claims, opts \\ [])

  def authorize(kind, claims, opts) when kind in @kinds and is_map(claims) do
    with :ok <- validate_claims(kind, claims),
         %Job{} = job <- Repo.get(Job, claims["job_id"]),
         :ok <- valid_job(job),
         :ok <- match_owner(job, claims),
         :ok <- match_environment(job, claims),
         :ok <- match_credential(job, claims),
         :ok <- match_cache_policy(job, claims, opts) do
      {:ok, %{job: job, environment: job.admitted_environment || %{}}}
    else
      nil -> {:error, :job_missing}
      {:error, _} = error -> error
      _ -> {:error, :runtime_scope_mismatch}
    end
  end

  def authorize(_, _, _), do: {:error, :invalid}

  @doc "Authorize a signed token in one call."
  def authorize_token(kind, token, opts \\ []) do
    with {:ok, claims} <- verify(kind, token), do: authorize(kind, claims, opts)
  end

  def max_age_seconds, do: @max_age_seconds

  @doc "Return the credential names captured in the job environment snapshot."
  def credential_names(%Job{} = job) do
    job.admitted_environment
    |> value("credentials", [])
    |> List.wrap()
    |> Enum.map(&value(&1, "name"))
    |> Enum.filter(&is_binary/1)
  end

  def authorize_credential(%Job{} = job, credential) when is_binary(credential) do
    if credential in credential_names(job),
      do: :ok,
      else: {:error, :credential_not_in_environment}
  end

  def authorize_credential(_, _), do: {:error, :credential_not_in_environment}

  @doc "Return one captured cache policy, including its immutable digest."
  def cache_snapshot(%Job{} = job, cache_group) when is_binary(cache_group) do
    job.admitted_environment
    |> value("caches", [])
    |> List.wrap()
    |> Enum.find(fn cache -> value(cache, "name") == cache_group end)
  end

  def cache_snapshot(_, _), do: nil

  @doc "Return the capability allowlist captured by the environment."
  def capabilities(%Job{} = job),
    do: job.admitted_environment |> value("capabilities", []) |> List.wrap()

  def capabilities(_), do: []

  @doc "Return the internal MCP declarations captured by the environment."
  def mcp_servers(%Job{} = job), do: job.admitted_environment |> value("mcp_servers", %{})
  def mcp_servers(_), do: %{}

  defp valid_job(%Job{id: id, user_id: owner, admitted_environment_digest: digest, status: status})
       when is_binary(id) and is_binary(owner) and is_binary(digest) and
              status in @active_statuses,
       do: :ok

  defp valid_job(_), do: {:error, :job_not_active}

  defp required_attributes("gateway", attrs), do: required(attrs, ["credential"])
  defp required_attributes("tools", attrs), do: required(attrs, [])

  defp required_attributes("supply_chain", attrs),
    do: required(attrs, ["cache_group", "policy_digest"])

  defp required_attributes("egress", _attrs), do: :ok

  defp required(attrs, keys) do
    if Enum.all?(keys, &(is_binary(Map.get(attrs, &1)) and Map.get(attrs, &1) != "")),
      do: :ok,
      else: {:error, :missing_runtime_claim}
  end

  defp validate_claims(kind, claims) when is_map(claims) do
    cond do
      claims["kind"] != kind ->
        {:error, :wrong_runtime_kind}

      not is_binary(claims["job_id"]) ->
        {:error, :invalid_job_claim}

      not is_binary(claims["token_owner"]) ->
        {:error, :invalid_owner_claim}

      not is_binary(claims["admitted_environment_digest"]) ->
        {:error, :invalid_environment_claim}

      kind == "gateway" and not is_binary(claims["credential"]) ->
        {:error, :invalid_credential_claim}

      kind == "supply_chain" and not is_binary(claims["cache_group"]) ->
        {:error, :invalid_cache_claim}

      kind == "supply_chain" and not is_binary(claims["policy_digest"]) ->
        {:error, :invalid_policy_claim}

      true ->
        :ok
    end
  end

  defp validate_claims(_, _), do: {:error, :invalid}

  defp match_owner(%Job{user_id: owner}, %{"token_owner" => owner}), do: :ok
  defp match_owner(_, _), do: {:error, :owner_mismatch}

  defp match_environment(%Job{admitted_environment_digest: digest}, %{"admitted_environment_digest" => digest}),
    do: :ok

  defp match_environment(_, _), do: {:error, :environment_changed}

  defp match_credential(%Job{} = job, %{"credential" => credential}) do
    if credential in credential_names(job),
      do: :ok,
      else: {:error, :credential_not_in_environment}
  end

  defp match_credential(_, _), do: :ok

  defp match_cache_policy(%Job{} = job, claims, opts) do
    case claims["cache_group"] do
      nil ->
        :ok

      group ->
        snapshot = cache_snapshot(job, group)
        digest = value(snapshot, "policy", %{}) |> value("digest")
        expected = claims["policy_digest"]
        current = Config.get_cache(group)
        current_digest = current && policy_digest(current.policy)

        if is_map(snapshot) and digest == expected and current_digest == expected and
             Keyword.get(opts, :cache_group) in [nil, group],
           do: :ok,
           else: {:error, :policy_changed}
    end
  end

  defp policy_digest(%{digest: digest}) when is_binary(digest), do: digest
  defp policy_digest(%{} = policy), do: Omashiki.SupplyChain.Policy.digest(policy)
  defp policy_digest(_), do: nil

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map) do
    atom_key =
      %{
        "credentials" => :credentials,
        "caches" => :caches,
        "name" => :name,
        "policy" => :policy,
        "digest" => :digest
      }[key]

    Map.get(map, key, if(atom_key, do: Map.get(map, atom_key, default), else: default))
  end

  defp value(_, _, default), do: default

  defp stringify(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp salt(kind), do: "omashiki.runtime." <> kind
end
