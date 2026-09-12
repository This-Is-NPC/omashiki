defmodule Omashiki.Worker.Snapshot do
  @moduledoc """
  Stateless worker executor that runs a claimed offer from its transport snapshot.

  Uses no database access; all inputs come from `Omashiki.Worker.Offer`.
  """

  @behaviour Omashiki.Worker.Executor

  alias Omashiki.Harness.CliJson
  alias Omashiki.Jobs.{Job, JobAttempt, Runner}
  alias Omashiki.Worker.{Complete, Offer}

  @sinks ~w(git files none)
  @conditions ~w(always on_success on_failure)

  @impl Omashiki.Worker.Executor
  def run(%Offer{} = offer), do: run(offer, [])

  def run(%Offer{} = offer, opts) do
    opts =
      :omashiki
      |> Application.get_env(:worker_snapshot_opts, [])
      |> Keyword.merge(opts)

    with :ok <- validate_offer(offer),
         :ok <- check_dependency_base(offer),
         :ok <- check_git_remote(offer) do
      job = build_job(offer)
      attempt = build_attempt(offer)
      environment = offer.admitted_environment || %{}
      execute(job, attempt, environment, offer, opts)
    end
  end

  defp execute(job, attempt, environment, offer, opts) do
    opts = provision_opts(opts, offer)
    pre_steps = Map.get(environment, "pre_steps", [])
    post_steps = Map.get(environment, "post_steps", [])
    timeout_ms = Map.get(environment, "timeout_ms", offer.timeout_ms)
    executables = Map.get(environment, "executables", [])
    container_mod = Keyword.get(opts, :container, Omashiki.Jobs.Runner.DockerContainer)
    adapter_mod = Keyword.get(opts, :adapter) || Omashiki.Presets.adapter(environment)

    state = %{
      job: job,
      attempt: attempt,
      environment: environment,
      sink: offer.sink,
      container: nil,
      outcome: :success,
      error: nil,
      harness_result: nil,
      container_mod: container_mod,
      adapter_mod: adapter_mod,
      opts: opts
    }

    with :ok <- validate_steps(pre_steps ++ post_steps, executables, timeout_ms),
         {:ok, container} <- container_mod.provision(job, attempt, environment, opts),
         state = %{state | container: container},
         state <- run_pre_steps(state, pre_steps, timeout_ms),
         state <- run_harness(state),
         state <- run_post_steps(state, post_steps, timeout_ms) do
      result =
        case state.outcome do
          :success -> finalize_success(state)
          :failure -> {:error, state.error || :attempt_failed}
        end

      destroy_container(state)
      result
    end
  end

  defp finalize_success(state) do
    opts = Keyword.put(state.opts, :update_task_branch, true)

    case state.container_mod.finalize(state.container, state.job, opts) do
      {:ok, final} -> {:ok, complete_from_finalize(state.sink, final, state)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_pre_steps(%{outcome: :failure} = state, _pre_steps, _timeout_ms), do: state

  defp run_pre_steps(state, pre_steps, timeout_ms) do
    Enum.reduce(pre_steps, state, fn step, acc ->
      case run_step(acc, step, timeout_ms) do
        {:ok, next} -> next
        {:error, reason} -> %{acc | outcome: :failure, error: reason}
      end
    end)
  end

  defp run_harness(%{outcome: :failure} = state), do: state

  defp run_harness(state) do
    case state.adapter_mod.invoke(
           %Omashiki.Harness.Invocation{
             instruction: state.job.payload["instruction"],
             context: CliJson.runtime_context(state.job)
           },
           harness_context(state)
         ) do
      {:ok, output} -> %{state | harness_result: output}
      {:error, reason} -> %{state | outcome: :failure, error: reason}
    end
  end

  defp run_post_steps(state, post_steps, timeout_ms) do
    Enum.reduce(post_steps, state, fn step, acc ->
      condition = Map.get(step, "condition", "always")

      if condition_matches?(condition, acc.outcome) do
        case run_step(acc, step, timeout_ms) do
          {:ok, next} -> next
          {:error, reason} -> %{acc | outcome: :failure, error: reason}
        end
      else
        acc
      end
    end)
  end

  defp run_step(
         %{container: container, container_mod: container_mod} = state,
         step,
         default_timeout
       ) do
    argv = Map.get(step, "argv", [])
    timeout_ms = Map.get(step, "timeout_ms", default_timeout)

    case container_mod.exec(container, argv, timeout_ms) do
      {:ok, _} -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_steps(steps, executables, default_timeout) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      argv = Map.get(step, "argv", [])
      condition = Map.get(step, "condition", "always")
      timeout_ms = Map.get(step, "timeout_ms", default_timeout)

      cond do
        condition not in @conditions ->
          {:halt, {:error, {:invalid_step, condition}}}

        not is_integer(timeout_ms) or timeout_ms <= 0 ->
          {:halt, {:error, {:invalid_step, :timeout}}}

        true ->
          case Runner.validate_argv(argv, executables) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp condition_matches?("always", _outcome), do: true
  defp condition_matches?("on_success", :success), do: true
  defp condition_matches?("on_failure", :failure), do: true
  defp condition_matches?(_, _), do: false

  defp harness_context(state) do
    container = state.container || %{}
    profile = Omashiki.Presets.profile(state.environment)
    capability = Omashiki.Runtime.Capability.from_sandbox(container, state.container_mod)

    %Omashiki.Harness.Context{
      job: state.job,
      credential: invoke_credential(state.environment),
      environment: state.environment,
      profile: profile,
      capability: capability,
      llm_egress: Map.get(container, :llm_egress),
      runtime_mounts: %{}
    }
  end

  defp invoke_credential(environment) do
    environment
    |> Map.get(:credentials, Map.get(environment, "credentials", []))
    |> List.wrap()
    |> List.first()
    |> Omashiki.Credentials.pin()
  end

  defp build_job(%Offer{} = offer) do
    %Job{
      id: offer.job_id,
      user_id: offer.user_id,
      repository: offer.repository,
      environment: offer.environment,
      payload: offer.payload || %{},
      admitted_environment: offer.admitted_environment || %{},
      admitted_environment_digest: offer.admitted_environment_digest,
      admitted_repository: relocate_repository(offer),
      admitted_repository_digest: offer.admitted_repository_digest,
      admitted_plugin: offer.admitted_plugin,
      admitted_plugin_digest: offer.admitted_plugin_digest,
      registry_digest: offer.registry_digest,
      status: "provisioning",
      current_attempt: offer.attempt_number,
      dependency_artifacts: []
    }
  end

  defp build_attempt(%Offer{} = offer) do
    %JobAttempt{
      id: offer.attempt_id,
      job_id: offer.job_id,
      number: offer.attempt_number,
      lease_token: offer.lease_token,
      status: "provisioning"
    }
  end

  defp relocate_repository(%Offer{sink: "git", admitted_repository: repo} = offer)
       when is_map(repo) do
    case Map.get(repo, "remote") do
      remote when is_binary(remote) and remote != "" ->
        mirror_path =
          Path.join([
            System.user_home!(),
            ".cache",
            "omashiki",
            "mirrors",
            manager_mirror_segment(offer),
            short_sha256(remote)
          ])

        Map.put(repo, "path", mirror_path)

      _ ->
        repo
    end
  end

  defp relocate_repository(%Offer{admitted_repository: repo}), do: repo

  defp check_dependency_base(%Offer{sink: "git", admitted_repository: %{"base" => base}})
       when is_binary(base) do
    if base == "dependency" or String.starts_with?(base, "dependency:") do
      {:error, :unresolved_dependency}
    else
      :ok
    end
  end

  defp check_dependency_base(_), do: :ok

  defp provision_opts(opts, %Offer{manager_url: url, manager_id: id}) do
    opts
    |> maybe_kw(:host_base_url, url)
    |> maybe_kw(:manager_id, id)
  end

  defp maybe_kw(opts, _key, nil), do: opts
  defp maybe_kw(opts, _key, ""), do: opts
  defp maybe_kw(opts, key, value), do: Keyword.put(opts, key, value)

  defp manager_mirror_segment(%Offer{manager_id: id}) when is_binary(id) and id != "" do
    sanitize_manager_id(id)
  end

  defp manager_mirror_segment(_), do: "local"

  defp sanitize_manager_id(id) do
    id
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
  end

  defp check_git_remote(%Offer{sink: "git", admitted_repository: %{"remote" => remote}})
       when is_binary(remote) and remote != "",
       do: :ok

  defp check_git_remote(%Offer{sink: "git"}), do: {:error, :missing_remote}
  defp check_git_remote(_), do: :ok

  defp validate_offer(%Offer{
         job_id: job_id,
         attempt_id: attempt_id,
         lease_token: lease_token,
         sink: sink,
         attempt_number: attempt_number,
         user_id: user_id,
         environment: environment,
         admitted_environment_digest: admitted_environment_digest,
         admitted_plugin_digest: admitted_plugin_digest
       })
       when is_binary(job_id) and is_binary(attempt_id) and is_binary(lease_token) and
              sink in @sinks and is_integer(attempt_number) and attempt_number > 0 and
              is_binary(user_id) and is_binary(environment) and
              is_binary(admitted_environment_digest) and is_binary(admitted_plugin_digest),
       do: :ok

  defp validate_offer(_), do: {:error, :invalid_offer}

  defp complete_from_finalize("git", final, state) do
    %Complete{
      kind: :git,
      remote: fetch_key(final, :remote),
      branch: fetch_key(final, :branch),
      base_sha: fetch_key(final, :base_sha),
      head_sha: fetch_key(final, :head_sha),
      summary: Runner.harness_summary(state.harness_result),
      changes: fetch_key(final, :changes)
    }
  end

  defp complete_from_finalize("files", final, _state) do
    result = fetch_key(final, :result) || %{}

    %Complete{
      kind: :files,
      changed_bytes: Map.get(result, "changed_bytes"),
      blob_digest: Map.get(result, "blob_digest"),
      blob_path: Map.get(result, "blob_path")
    }
  end

  defp complete_from_finalize("none", final, _state) do
    result = fetch_key(final, :result) || %{}

    %Complete{
      kind: :none,
      changed_bytes: Map.get(result, "changed_bytes", 0)
    }
  end

  defp fetch_key(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp fetch_key(_, _), do: nil

  defp short_sha256(value) when is_binary(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end

  defp destroy_container(%{container: container, container_mod: container_mod})
       when is_map(container) do
    container_mod.destroy(container)
  end

  defp destroy_container(_), do: :ok
end
