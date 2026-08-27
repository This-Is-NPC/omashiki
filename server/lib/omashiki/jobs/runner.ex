defmodule Omashiki.Jobs.Runner.Container do
  @moduledoc "Container boundary used by the one-attempt runner."

  @callback provision(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback exec(map(), [String.t()], pos_integer()) :: {:ok, map()} | {:error, term()}
  @callback finalize(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback destroy(map()) :: :ok | {:error, term()}
end

defmodule Omashiki.Jobs.Runner.DockerContainer do
  @moduledoc "Production container boundary backed by the hardened Docker manager."

  @behaviour Omashiki.Jobs.Runner.Container

  alias Omashiki.Jobs.{GitArtifact, Job, JobAttempt, WorkArtifact}
  alias Omashiki.Runtime.ContainerManager

  @impl true
  def provision(%Job{} = job, %JobAttempt{} = attempt, environment, opts) do
    opts = Keyword.put_new(opts, :preset, profile_for(environment))

    with {:ok, sink} <- environment_sink(environment) do
      provision_fn(job, attempt, sink, opts, fn artifact ->
        opts = Keyword.put(opts, :worktree_path, artifact.path)

        case ContainerManager.provision_for_job(job, attempt, environment, opts) do
          {:ok, container} ->
            container_id = Map.get(container, :id) || Map.get(container, :sandbox_id)

            {:ok,
             Map.merge(container, %{
               artifact: artifact,
               id: container_id,
               worktree_path: artifact.path
             })}

          error ->
            error
        end
      end)
    end
  end

  defp provision_fn(job, attempt, "git", opts, callback),
    do: GitArtifact.provision(job, attempt, opts, callback)

  defp provision_fn(job, _attempt, sink, opts, callback) when sink in ["files", "none"],
    do: WorkArtifact.provision(job, sink, opts, callback)

  defp provision_fn(_job, _attempt, sink, _opts, _callback),
    do: {:error, {:unsupported_sink, sink}}

  @impl true
  def exec(%{id: container_id}, argv, timeout_ms),
    do: ContainerManager.exec(container_id, argv, timeout_ms)

  @impl true
  def finalize(%{artifact: %{branch: _}} = container, job, opts),
    do: GitArtifact.finalize(container.artifact, job, opts)

  def finalize(%{artifact: %{sink: sink}} = container, job, opts) when sink in ["files", "none"],
    do: WorkArtifact.finalize(container.artifact, job, opts)

  def finalize(container, job, opts),
    do: Omashiki.Jobs.Runner.Finalizer.finalize(container, job, opts)

  @impl true
  def destroy(%{id: container_id, artifact: %{branch: _} = artifact, preserve_artifact: true}) do
    _ = ContainerManager.destroy(container_id)
    GitArtifact.cleanup(artifact, preserve_branch: true)
  end

  @impl true
  def destroy(%{id: container_id, artifact: %{branch: _} = artifact}) do
    _ = ContainerManager.destroy(container_id)
    GitArtifact.cleanup(artifact, preserve_branch: false)
  end

  @impl true
  def destroy(%{id: container_id, artifact: %{sink: _} = artifact}) do
    _ = ContainerManager.destroy(container_id)
    WorkArtifact.cleanup(artifact)
  end

  def destroy(%{id: container_id}), do: ContainerManager.destroy(container_id)

  def cancel_scope(scope_id), do: ContainerManager.cancel_scope(scope_id)

  defp environment_sink(environment) when is_map(environment) do
    case Map.get(environment, "sink") || Map.get(environment, :sink) do
      nil -> {:error, {:unsupported_sink, :missing}}
      sink when sink in ["git", "files", "none"] -> {:ok, sink}
      sink -> {:error, {:unsupported_sink, sink}}
    end
  end

  defp environment_sink(_), do: {:error, {:unsupported_sink, :missing}}

  defp profile_for(environment) do
    Omashiki.Harnesses.profile(environment)
  end
end

defmodule Omashiki.Jobs.Runner.Finalizer do
  @moduledoc "Collects clean committed-worktree metadata without changing Git state."

  alias Omashiki.Jobs.Job

  def finalize(%{worktree_path: path}, %Job{} = job, _opts) when is_binary(path) do
    with {:ok, branch} <- git(path, ["symbolic-ref", "--short", "HEAD"]),
         {:ok, head_sha} <- git(path, ["rev-parse", "HEAD"]),
         {:ok, base_sha} <- base_sha(path, job),
         {:ok, clean} <- clean?(path) do
      {:ok,
       %{
         branch: branch,
         base_sha: base_sha,
         head_sha: head_sha,
         worktree_clean: clean,
         result: %{"head_sha" => head_sha}
       }}
    end
  end

  def finalize(_container, _job, _opts), do: {:error, :worktree_unavailable}

  defp base_sha(path, %Job{admitted_repository: %{"base_branch" => branch}}),
    do: git(path, ["rev-parse", branch])

  defp base_sha(_path, _job), do: {:error, :base_branch_unavailable}

  defp clean?(path) do
    case System.cmd("git", ["-C", path, "status", "--porcelain"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output) == ""}
      {output, status} -> {:error, {:git_failed, status, summary(output)}}
    end
  rescue
    error -> {:error, {:git_exception, inspect(error)}}
  end

  defp git(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:git_failed, status, summary(output)}}
    end
  rescue
    error -> {:error, {:git_exception, inspect(error)}}
  end

  defp summary(output), do: output |> to_string() |> String.trim() |> String.slice(0, 1_024)
end

defmodule Omashiki.Jobs.Runner do
  @moduledoc "Executes exactly one claimed attempt through its governed lifecycle."

  import Ecto.Query

  alias Omashiki.Jobs.{Job, JobAttempt, JobStep}
  alias Omashiki.Repo

  @unsafe_executables ~w(sh bash dash zsh fish cmd powershell pwsh env xargs python python2 python3 node perl ruby php lua busybox make awk)
  @conditions ~w(always on_success on_failure)
  @max_output_bytes 4_096

  @doc "Run one claimed attempt. The runner never creates a second attempt."
  def run(attempt_or_id, opts \\ []) do
    with {:ok, attempt} <- load_attempt(attempt_or_id),
         :ok <- active_attempt?(attempt) do
      with_lease_heartbeat(attempt, opts, fn -> execute(attempt, opts) end)
    end
  end

  @doc "Validate an argv command against an environment declaration."
  def validate_argv(argv, executables) when is_list(executables) do
    cond do
      argv == [] or not Enum.all?(argv, &valid_arg?/1) ->
        {:error, {:invalid_argv, :malformed}}

      Path.basename(hd(argv)) in @unsafe_executables ->
        {:error, {:invalid_argv, :unsafe_executable}}

      hd(argv) not in executables ->
        {:error, {:invalid_argv, :undeclared_executable}}

      true ->
        :ok
    end
  end

  def validate_argv(_argv, _executables), do: {:error, {:invalid_argv, :malformed}}

  defp execute(%JobAttempt{} = attempt, opts) do
    job = Repo.get!(Job, attempt.job_id)
    environment = job.admitted_environment || %{}
    pre_steps = Keyword.get(opts, :pre_steps, Map.get(environment, "pre_steps", []))
    post_steps = Keyword.get(opts, :post_steps, Map.get(environment, "post_steps", []))
    plans = step_plans(pre_steps, post_steps, Map.get(environment, "timeout_ms", 60_000))
    steps = persist_plans!(attempt, plans)

    state = %{
      attempt: attempt,
      job: job,
      environment: environment,
      opts: opts,
      steps: steps,
      container: nil,
      container_started: false,
      outcome: :success,
      error: nil,
      harness_result: %{}
    }

    try do
      state =
        case validate_plans(plans, Map.get(environment, "executables", [])) do
          :ok -> run_provision(state)
          {:error, reason} -> fail_state(state, reason)
        end

      state =
        if state.outcome == :success,
          do: mark_running_and_run(state),
          else: skip_until_finalize(state)

      state = run_finalization(state)
      _state = run_cleanup(state)

      {:ok, Repo.get!(Job, state.job.id)}
    rescue
      error ->
        _ = best_effort_cleanup(state)
        _ = best_effort_failure(attempt, {:runner_exception, error})
        {:error, {:runner_exception, error}}
    catch
      kind, reason ->
        _ = best_effort_cleanup(state)
        _ = best_effort_failure(attempt, {:runner_throw, kind, reason})
        {:error, {:runner_throw, kind, reason}}
    end
  end

  defp run_provision(state) do
    step = step(state, "provision")

    {state, result} =
      invoke_step(state, step, %{}, fn ->
        container_mod(state).provision(state.job, state.attempt, state.environment, state.opts)
      end)

    case result do
      {:ok, container} -> %{state | container: container}
      {:error, reason} -> fail_state(state, reason)
    end
  end

  defp mark_running_and_run(state) do
    case Omashiki.Jobs.mark_running(state.attempt, lease_token(state)) do
      {:ok, _job} ->
        state
        |> Map.put(:container_started, true)
        |> run_pre_steps()

      {:error, reason} ->
        fail_state(state, reason)
    end
  end

  defp run_pre_steps(%{outcome: :failure} = state) do
    state
    |> skip_pending_steps(["pre"])
    |> run_harness()
    |> run_post_steps()
  end

  defp run_pre_steps(state) do
    case cancellation_reason(state) do
      nil -> run_pre_steps_uncancelled(state)
      reason -> fail_state(state, reason) |> run_pre_steps()
    end
  end

  defp run_pre_steps_uncancelled(state) do
    state.steps
    |> Enum.filter(&(&1.kind == "pre"))
    |> Enum.reduce_while(state, fn step, acc ->
      {acc, result} = run_command_step(acc, step)

      if result == :ok, do: {:cont, acc}, else: {:halt, fail_state(acc, result)}
    end)
    |> run_harness()
    |> run_post_steps()
  end

  defp run_harness(%{outcome: :failure} = state), do: skip_step(state, "preset")

  defp run_harness(state) do
    step = step(state, "preset")

    {state, result} =
      invoke_step(state, step, %{"payload" => state.job.payload}, fn ->
        adapter_mod(state).invoke(
          %Omashiki.Harness.Invocation{
            instruction: state.job.payload["instruction"],
            context: state.job.payload["context"]
          },
          harness_context(state)
        )
      end)

    case result do
      {:ok, output} -> %{state | harness_result: output}
      {:error, reason} -> fail_state(state, reason)
    end
  end

  defp run_post_steps(state) do
    state.steps
    |> Enum.filter(&(&1.kind == "post"))
    |> Enum.reduce(state, fn step, acc ->
      condition = step.input["condition"]

      if condition_matches?(condition, acc.outcome) do
        {acc, result} = run_command_step(acc, step)
        if result == :ok, do: acc, else: fail_state(acc, result)
      else
        skip_step(acc, step.key)
      end
    end)
  end

  defp run_finalization(state) do
    step = step(state, "finalization")
    input = %{"outcome" => Atom.to_string(state.outcome)}

    {state, result} =
      invoke_step(state, step, input, fn ->
        complete_attempt(state)
      end)

    case result do
      {:ok, %{"preserve_artifact" => true}} ->
        put_in(state, [:container, :preserve_artifact], true)

      {:ok, _} ->
        state

      {:error, reason} ->
        fail_state(state, reason)
    end
  end

  defp run_cleanup(state) do
    step = step(state, "cleanup")

    {state, result} =
      invoke_step(state, step, %{}, fn ->
        case state.container do
          nil -> {:ok, %{status: "no_container"}}
          container -> container_mod(state).destroy(container)
        end
      end)

    if match?({:error, _}, result), do: fail_state(state, elem(result, 1)), else: state
  end

  defp complete_attempt(%{outcome: :success} = state) do
    opts = Keyword.put(state.opts, :update_task_branch, true)

    case container_mod(state).finalize(state.container, state.job, opts) do
      {:ok, final} ->
        attrs = %{
          branch: Map.get(final, :branch, Map.get(final, "branch")),
          base_sha: Map.get(final, :base_sha, Map.get(final, "base_sha")),
          head_sha: Map.get(final, :head_sha, Map.get(final, "head_sha")),
          worktree_clean: Map.get(final, :worktree_clean, Map.get(final, "worktree_clean")),
          result:
            deep_stringify(
              Map.get(final, :result, Map.get(final, "result", state.harness_result))
            )
        }

        case Omashiki.Jobs.complete(state.attempt, lease_token(state), :succeeded, attrs) do
          {:ok, _attempt} ->
            {:ok,
             %{
               "status" => "succeeded",
               "preserve_artifact" =>
                 is_map(state.container) and Map.has_key?(state.container, :artifact)
             }}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        error = error_map("finalization_failed", reason)
        _ = Omashiki.Jobs.complete(state.attempt, lease_token(state), :failed, %{error: error})
        {:error, reason}
    end
  end

  defp complete_attempt(%{container_started: true, container: container} = state)
       when is_map(container) and map_size(container) > 0 do
    preserve = git_artifact?(container)

    if preserve do
      _ = container_mod(state).finalize(container, state.job, state.opts)
    end

    error = state.error || error_map("attempt_failed", "attempt did not complete")

    case Omashiki.Jobs.complete(state.attempt, lease_token(state), :failed, %{error: error}) do
      {:ok, _attempt} -> {:ok, %{"status" => "failed", "preserve_artifact" => preserve}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp complete_attempt(state) do
    error = state.error || error_map("attempt_failed", "attempt did not complete")

    case Omashiki.Jobs.complete(state.attempt, lease_token(state), :failed, %{error: error}) do
      {:ok, _attempt} -> {:ok, %{"status" => "failed"}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp git_artifact?(%{artifact: %{task_branch: _}}), do: true
  defp git_artifact?(_), do: false

  defp run_command_step(state, step) do
    argv = step.input["argv"]
    timeout_ms = step.input["timeout_ms"]

    invoke_step(state, step, step.input, fn ->
      container_mod(state).exec(state.container, argv, timeout_ms)
    end)
    |> then(fn {state, result} ->
      case result do
        {:ok, _output} -> {state, :ok}
        {:error, reason} -> {fail_state(state, reason), reason}
      end
    end)
  end

  defp invoke_step(state, step, input, fun) do
    started_at = DateTime.utc_now(:microsecond)
    monotonic_started_at = System.monotonic_time(:millisecond)
    step = update_step!(step, %{status: "running", input: input, started_at: started_at})

    result = safe_call(fun)
    finished_at = DateTime.utc_now(:microsecond)

    case result do
      {:ok, output} ->
        emit_step_telemetry(step, monotonic_started_at, "ok")

        step =
          update_step!(step, %{
            status: "succeeded",
            output: output_summary(output),
            finished_at: finished_at
          })

        {%{state | steps: replace_step(state.steps, step)}, {:ok, output}}

      {:error, reason} ->
        emit_step_telemetry(step, monotonic_started_at, "error")
        error = error_map("step_failed", reason)
        step = update_step!(step, %{status: "failed", error: error, finished_at: finished_at})
        {%{state | steps: replace_step(state.steps, step)}, {:error, reason}}
    end
  end

  defp emit_step_telemetry(step, started_at, outcome) do
    :telemetry.execute(
      [:omashiki, :runtime, :step],
      %{duration_ms: max(System.monotonic_time(:millisecond) - started_at, 0)},
      %{kind: step.kind, outcome: outcome}
    )
  end

  defp safe_call(fun) do
    case fun.() do
      :ok -> {:ok, %{status: "ok"}}
      {:ok, _} = result -> result
      {:error, _} = result -> result
      other -> {:error, {:invalid_boundary_result, other}}
    end
  rescue
    error -> {:error, {:exception, inspect(error)}}
  catch
    kind, reason -> {:error, {:throw, kind, inspect(reason)}}
  end

  defp with_lease_heartbeat(%JobAttempt{lease_token: token} = attempt, opts, fun)
       when is_binary(token) do
    if Keyword.get(opts, :heartbeat, true) do
      do_with_lease_heartbeat(attempt, token, opts, fun)
    else
      fun.()
    end
  end

  defp with_lease_heartbeat(_attempt, _opts, fun), do: fun.()

  defp do_with_lease_heartbeat(attempt, token, opts, fun) do
    interval = Keyword.get(opts, :heartbeat_interval_ms, 10_000)
    heartbeat = spawn(fn -> heartbeat_loop(attempt.id, token, interval) end)

    try do
      fun.()
    after
      stop_heartbeat(heartbeat)
    end
  end

  defp heartbeat_loop(attempt_id, token, interval) do
    receive do
      {:stop, caller} ->
        send(caller, {:heartbeat_stopped, self()})
        :ok
    after
      interval ->
        case Omashiki.Jobs.heartbeat(attempt_id, token) do
          {:ok, _attempt} -> heartbeat_loop(attempt_id, token, interval)
          {:error, _reason} -> :ok
        end
    end
  end

  defp stop_heartbeat(heartbeat) do
    monitor = Process.monitor(heartbeat)
    send(heartbeat, {:stop, self()})

    receive do
      {:heartbeat_stopped, ^heartbeat} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {:DOWN, ^monitor, :process, ^heartbeat, _reason} ->
        :ok
    after
      1_000 ->
        Process.exit(heartbeat, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^heartbeat, _reason} -> :ok
        after
          1_000 -> Process.demonitor(monitor, [:flush])
        end
    end
  end

  defp persist_plans!(attempt, plans) do
    existing = Repo.all(from(s in JobStep, where: s.attempt_id == ^attempt.id))

    Enum.map(plans, fn plan ->
      case Enum.find(existing, &(&1.key == plan.key)) do
        %JobStep{} = step ->
          step

        nil ->
          %JobStep{}
          |> JobStep.changeset(%{
            attempt_id: attempt.id,
            sequence: plan.sequence,
            key: plan.key,
            kind: plan.kind,
            status: "pending",
            input: plan.input
          })
          |> Repo.insert!()
      end
    end)
  end

  defp step_plans(pre_steps, post_steps, timeout_ms) do
    pre = Enum.with_index(pre_steps, 1)
    post = Enum.with_index(post_steps, 1)
    harness_sequence = 2 + length(pre)
    post_start = harness_sequence + 1
    finalization_sequence = post_start + length(post)

    [%{sequence: 1, key: "provision", kind: "provision", input: %{}}] ++
      Enum.map(pre, &plan(&1, "pre", 2, timeout_ms)) ++
      [%{sequence: harness_sequence, key: "preset", kind: "preset", input: %{}}] ++
      Enum.map(post, &plan(&1, "post", post_start, timeout_ms)) ++
      [
        %{
          sequence: finalization_sequence,
          key: "finalization",
          kind: "finalization",
          input: %{}
        },
        %{
          sequence: finalization_sequence + 1,
          key: "cleanup",
          kind: "cleanup",
          input: %{}
        }
      ]
  end

  defp plan({step, index}, kind, offset, timeout_ms) do
    %{
      sequence: offset + index - 1,
      key: "#{kind}-#{index}",
      kind: kind,
      input: %{
        "argv" => Map.get(step, "argv", []),
        "condition" => Map.get(step, "condition", "always"),
        "timeout_ms" => Map.get(step, "timeout_ms", timeout_ms)
      }
    }
  end

  defp validate_plans(plans, executables) do
    Enum.reduce_while(plans, :ok, fn plan, :ok ->
      case plan.kind do
        kind when kind in ["pre", "post"] ->
          with :ok <- validate_argv(plan.input["argv"], executables),
               true <- plan.input["condition"] in @conditions,
               true <- is_integer(plan.input["timeout_ms"]) and plan.input["timeout_ms"] > 0 do
            {:cont, :ok}
          else
            false -> {:halt, {:error, {:invalid_step, plan.key}}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        _ ->
          {:cont, :ok}
      end
    end)
  end

  defp condition_matches?("always", _outcome), do: true
  defp condition_matches?("on_success", :success), do: true
  defp condition_matches?("on_failure", :failure), do: true
  defp condition_matches?(_, _), do: false

  defp skip_until_finalize(state) do
    skip_pending_steps(state, ~w(pre harness post))
  end

  defp skip_pending_steps(state, kinds) do
    Enum.reduce(state.steps, state, fn step, acc ->
      if step.kind in kinds and step.status == "pending", do: skip_step(acc, step.key), else: acc
    end)
  end

  defp skip_step(state, key) do
    step = step(state, key)

    if step.status == "pending" do
      now = DateTime.utc_now(:microsecond)

      updated =
        update_step!(step, %{status: "skipped", started_at: now, finished_at: now})

      %{state | steps: replace_step(state.steps, updated)}
    else
      state
    end
  end

  defp fail_state(%{outcome: :success} = state, reason),
    do: %{state | outcome: :failure, error: error_map("attempt_failed", reason)}

  defp fail_state(state, _reason), do: state

  defp cancellation_reason(state) do
    case Repo.get(Job, state.job.id) do
      %Job{status: status} when status in ["cancelled", "failed", "succeeded"] ->
        {:attempt_already_terminal, status}

      _ ->
        nil
    end
  end

  defp best_effort_failure(attempt, reason) do
    if attempt.status in ["provisioning", "running"] and is_binary(attempt.lease_token) do
      _ =
        Omashiki.Jobs.complete(attempt, attempt.lease_token, :failed, %{
          error: error_map("runner_crash", reason)
        })
    end

    :ok
  rescue
    _ -> :ok
  end

  defp best_effort_cleanup(state) do
    _ = run_cleanup(state)
    :ok
  rescue
    _ -> :ok
  end

  defp load_attempt(%JobAttempt{} = attempt), do: {:ok, Repo.get!(JobAttempt, attempt.id)}
  defp load_attempt(id) when is_binary(id), do: load_attempt(Repo.get(JobAttempt, id))
  defp load_attempt(nil), do: {:error, :attempt_not_found}
  defp load_attempt(_), do: {:error, :invalid_attempt}

  defp active_attempt?(%JobAttempt{status: status}) when status in ["provisioning", "running"],
    do: :ok

  defp active_attempt?(%JobAttempt{status: status}), do: {:error, {:attempt_not_active, status}}

  defp container_mod(state),
    do: Keyword.get(state.opts, :container, Omashiki.Jobs.Runner.DockerContainer)

  defp adapter_mod(state) do
    Keyword.get(state.opts, :adapter) || Omashiki.Harnesses.adapter(state.environment)
  end

  defp harness_context(state) do
    container = state.container || %{}
    profile = Omashiki.Harnesses.profile(state.environment)
    capability = Omashiki.Runtime.Capability.from_container(container, container_mod(state))

    %Omashiki.Harness.Context{
      job: state.job,
      environment: state.environment,
      profile: profile,
      capability: capability,
      llm_egress: Map.get(container, :llm_egress),
      runtime_mounts: %{}
    }
  end

  defp lease_token(state), do: Keyword.get(state.opts, :lease_token, state.attempt.lease_token)
  defp step(state, key), do: Enum.find(state.steps, &(&1.key == key))

  defp replace_step(steps, updated),
    do: Enum.map(steps, &if(&1.id == updated.id, do: updated, else: &1))

  defp update_step!(step, attrs), do: step |> JobStep.changeset(attrs) |> Repo.update!()

  defp output_summary(output) when is_map(output), do: deep_stringify(output)
  defp output_summary(output), do: %{"output" => truncate(output)}

  defp error_map(code, reason) when is_binary(code),
    do: %{
      "code" => code,
      "message" => truncate(reason),
      "details" => %{"reason" => truncate(reason)}
    }

  defp truncate(value) when is_binary(value), do: String.slice(value, 0, @max_output_bytes)
  defp truncate(value), do: value |> inspect() |> String.slice(0, @max_output_bytes)

  defp deep_stringify(%_{} = struct), do: struct |> Map.from_struct() |> deep_stringify()

  defp deep_stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), deep_stringify(value)} end)

  defp deep_stringify(list) when is_list(list), do: Enum.map(list, &deep_stringify/1)
  defp deep_stringify(value) when is_binary(value), do: truncate(value)
  defp deep_stringify(value), do: value

  defp valid_arg?(arg),
    do: is_binary(arg) and arg != "" and String.valid?(arg) and not String.contains?(arg, <<0>>)
end
