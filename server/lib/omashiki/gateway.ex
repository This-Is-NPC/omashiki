defmodule Omashiki.Gateway do
  @moduledoc """
  OpenAI-compatible LLM **ingress** for agent containers.

  Runtime containers never hold the provider API key. Provision points OpenCode at
  this gateway (`options.baseURL`); the gateway authenticates a job-bound
  token, applies budget + circuit breaker, forwards through a **provider
  outbound adapter** (`Omashiki.Gateway.Provider`), and records
  `usage_ledger` from adapter-reported usage (field truth), not from
  engine auto-report.

  ## Outbound seam

  Inbound stays OpenAI-compat. Outbound is selected per credential via
  `Gateway.Provider.adapter/1` — see that module and
  `Gateway.Providers.OpenaiCompat` (first adapter) /
  `Gateway.Providers.AnthropicNative` (placeholder for Messages + real
  cache tokens).

  ## Network / Tools.Proxy

  Once engines only reach the LLM through this gateway, containers can
  drop general internet (`NetworkMode` private) and Tools.Proxy becomes
  the sole MCP egress — see Phase 3 moduledoc. That lock is opt-in via
  `:agent_network_mode`; this module does not force it.

  Ledger `request_id` is stable (`provider id` or `task:…:turn:…`) so
  `UNIQUE(request_id)` collides on retry instead of double-billing.
  """

  require Logger

  import Ecto.Query

  alias Omashiki.Credentials
  alias Omashiki.Credentials.Credential
  alias Omashiki.Gateway.CircuitBreaker
  alias Omashiki.Gateway.Budget
  alias Omashiki.Gateway.Provider
  alias Omashiki.Gateway.Providers.OpenaiCompat
  alias Omashiki.Repo
  alias Omashiki.Runtime.Claims
  alias Omashiki.UsageLedger

  # ---------------------------------------------------------------------------
  # Token / URL
  # ---------------------------------------------------------------------------

  def sign_token(job_id, token_owner, environment_digest, credential_name)
      when is_binary(job_id) and is_binary(token_owner) and is_binary(environment_digest) and
             is_binary(credential_name) do
    with %Omashiki.Jobs.Job{} = job <- Repo.get(Omashiki.Jobs.Job, job_id),
         {:ok, token} <-
           Claims.issue("gateway", job, %{
             credential: credential_name,
             token_owner: token_owner,
             environment_digest: environment_digest
           }) do
      token
    else
      _ -> nil
    end
  end

  def verify_token(token), do: Claims.verify("gateway", token)

  @doc "Base URL containers use to reach the gateway (no trailing /v1)."
  def base_url do
    Application.get_env(:omashiki, :llm_gateway_base_url) ||
      System.get_env("OMASHIKI_LLM_GATEWAY_BASE_URL") ||
      default_base_url()
  end

  defp default_base_url do
    port =
      case Application.get_env(:omashiki, OmashikiWeb.Endpoint) do
        opts when is_list(opts) ->
          Keyword.get(Keyword.get(opts, :http, []), :port, 4000)

        _ ->
          4000
      end

    host =
      if Application.get_env(:omashiki, :agent_network_mode) == "host",
        do: "127.0.0.1",
        else: "host.docker.internal"

    "http://#{host}:#{port}"
  end

  @doc "OpenAI-compatible baseURL injected into the engine (`…/api/v1/gateway/v1`)."
  def openai_base_url do
    String.trim_trailing(base_url(), "/") <> "/api/v1/gateway/v1"
  end

  # ---------------------------------------------------------------------------
  # Chat completions
  # ---------------------------------------------------------------------------

  @doc """
  Handle one OpenAI-compatible chat completion request.

  Returns `{:ok, response_map}` or `{:error, reason_map}`.
  """
  def chat_completions(body, claims) when is_map(body) and is_map(claims) do
    credential_name =
      claims["credential"] || claims[:credential] || claims["credential_id"] ||
        claims[:credential_id]

    with {:ok, %{job: job}} <- Claims.authorize("gateway", claims),
         %Credential{} = cred <-
           Credentials.get_credential(credential_name) || :credential_missing,
         :ok <- Claims.authorize_credential(job, credential_name),
         :ok <- Budget.check(job),
         requested <- requested_model(body, cred),
         {:ok, result, used_cred, used_model} <-
           forward_with_fallback(cred, body, requested, Claims.credential_names(job)) do
      _ = record_usage(job, used_cred, used_model, result.usage)
      _ = emit_llm_called(job, used_cred, used_model, result, "ok")
      {:ok, result.response}
    else
      {:error, reason} when reason in [:job_missing, :job_not_active, :expired, :invalid] ->
        {:error, %{status: 401, error: %{message: Atom.to_string(reason), type: "auth"}}}

      {:error, reason}
      when reason in [:owner_mismatch, :environment_changed, :credential_not_in_environment] ->
        {:error, %{status: 403, error: %{message: Atom.to_string(reason), type: "auth"}}}

      :credential_missing ->
        {:error, %{status: 401, error: %{message: "credential_missing", type: "auth"}}}

      {:error, :budget_exceeded} ->
        _ = emit_budget_denied(claims["job_id"])
        {:error, %{status: 429, error: %{message: "budget_exceeded", type: "budget"}}}

      {:error, :circuit_open} ->
        {:error, %{status: 503, error: %{message: "circuit_open", type: "upstream"}}}

      {:error, reason} when is_map(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, %{status: 502, error: %{message: inspect(reason), type: "upstream"}}}
    end
  end

  # The name the caller asked for, normalized. Anchored to the *primary*
  # credential because that is the one the request was addressed to; the
  # fallback hops translate this name against themselves in `hop_model/3`.
  defp requested_model(body, %Credential{} = cred) do
    requested = body["model"] || body[:model] || cred.model

    # Strip optional "gateway/" or "provider/" prefix from engine.
    requested
    |> to_string()
    |> String.split("/")
    |> List.last()
  rescue
    _ -> cred.model
  end

  # Resolve the model against the credential that is about to serve the hop.
  #
  # A credential's alias table always wins — that is the operator's declared
  # translation for a foreign model name. Without an alias the two roles
  # differ, and the difference is the whole point:
  #
  #   * `:primary` honours the requested name verbatim. The request was
  #     addressed to this credential, so an unlisted name is plausibly still
  #     one it serves (any OpenAI model against an OpenAI credential).
  #
  #   * `:fallback` falls back to the credential's *own* declared model. A
  #     fallback is a different provider/account that never saw the request;
  #     forwarding the primary's model name at it either fails outright or —
  #     worse — succeeds and bills the ledger for a model that never ran.
  #
  # Provision points the engine at `modelID: credential.model` of the primary
  # (see `Harness.OpenCode`), so in practice the requested name *is* the
  # primary's model. Resolving it verbatim on a fallback hop is exactly the
  # cross-provider mis-attribution this guards against.
  defp hop_model(requested, %Credential{} = cred, :primary) do
    Map.get(normalize_aliases(cred.model_aliases), requested) || requested
  end

  defp hop_model(requested, %Credential{} = cred, :fallback) do
    Map.get(normalize_aliases(cred.model_aliases), requested) || cred.model || requested
  end

  defp normalize_aliases(aliases) when is_map(aliases) do
    Map.new(aliases, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp normalize_aliases(_), do: %{}

  # Returns `{:ok, result, credential, model}` — the model is returned because
  # each hop resolves its own, and the ledger must record the one that ran.
  defp forward_with_fallback(%Credential{} = cred, body, requested, allowed_names) do
    fallbacks = Enum.map(load_fallback_credentials(cred, allowed_names), &{&1, :fallback})
    chain = [{cred, :primary} | fallbacks]

    Enum.reduce_while(chain, {:error, :circuit_open}, fn {c, role}, _acc ->
      case CircuitBreaker.allow?(c.name) do
        :ok ->
          model = hop_model(requested, c, role)

          case Provider.chat_completions(c, body, model) do
            {:ok, result} ->
              CircuitBreaker.record_success(c.name)
              {:halt, {:ok, result, c, model}}

            {:error, reason} ->
              CircuitBreaker.record_failure(c.name)
              Logger.warning("[Gateway] upstream failed for #{c.name}: #{inspect(reason)}")
              {:cont, {:error, reason}}
          end

        :open ->
          {:cont, {:error, :circuit_open}}
      end
    end)
  end

  defp load_fallback_credentials(%Credential{fallback_chain: ids}, allowed_names)
       when is_list(ids) do
    ids
    |> Enum.filter(&(&1 in allowed_names))
    |> Enum.map(&Credentials.get_credential/1)
    |> Enum.reject(&is_nil/1)
  end

  defp load_fallback_credentials(_, _), do: []

  @doc "Delegate for tests / callers that still probe default OAI upstream URLs."
  def upstream_base(cred), do: OpenaiCompat.upstream_base(cred)

  defp record_usage(%{id: job_id}, %Credential{} = cred, model, usage) when is_map(usage) do
    turn = next_turn(job_id)

    # UNIQUE(request_id) must collide on retry. Never invent a UUID.
    # Stable derivation: provider id or job/turn identity.
    stable = usage.provider_request_id || "job:#{job_id}:turn:#{turn}"
    request_id = "gateway:#{stable}"

    UsageLedger.record(%{
      request_id: request_id,
      job_id: job_id,
      turn: turn,
      provider: cred.provider,
      model: model,
      input_tokens: usage.input_tokens || 0,
      # nil = adapter did not report — never coerce to 0 (fiction).
      cached_input_tokens: usage.cached_input_tokens,
      output_tokens: usage.output_tokens || 0,
      reasoning_tokens: usage.reasoning_tokens,
      cache_write_tokens: usage.cache_write_tokens,
      provider_request_id: usage.provider_request_id,
      occurred_at: DateTime.utc_now(:microsecond)
    })
  end

  defp next_turn(job_id) do
    from(e in Omashiki.UsageLedger.Entry,
      where: e.job_id == ^job_id,
      select: coalesce(max(e.turn), 0)
    )
    |> Repo.one()
    |> Kernel.+(1)
  end

  defp emit_llm_called(%{id: job_id}, cred, model, %{response: response, usage: usage}, outcome) do
    Logger.debug("gateway LLM request",
      job_id: job_id,
      outcome: outcome,
      provider: cred.provider,
      model: model,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      provider_request_id: response["id"]
    )
  end

  defp emit_budget_denied(job_id) when is_binary(job_id) do
    Logger.warning("gateway budget denied", job_id: job_id)
    :ok
  end

  defp emit_budget_denied(_), do: :ok
end
