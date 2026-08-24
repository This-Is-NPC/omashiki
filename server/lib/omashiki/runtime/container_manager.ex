defmodule Omashiki.Runtime.ContainerManager do
  @moduledoc """
  GenServer that talks to the Docker Engine API (via Unix socket) to
  provision per-job agent containers and to clean up orphaned containers.

  Each container runs the harness selected by the job's runtime profile and
  bind-mounts the job's worktree. The chosen host port is reported back so the
  harness client can connect.
  """

  use GenServer
  @behaviour Omashiki.Runtime.ContainerManager.Behaviour
  require Logger

  alias Omashiki.Jobs.Job
  alias Omashiki.SupplyChain.{Policy, Preflight, Proxy, SocketBridge}
  alias Omashiki.Runtimes.{CacheMaintenance, CacheSnapshot}

  @docker_api_version "v1.43"
  @container_label "omashiki"
  @stop_timeout 10
  @host_port_range_start 14_096
  @host_port_range_end 14_999
  @agent_home "/tmp/agent-home"
  @host_socket "/run/omashiki/host.sock"
  @llm_egress_socket "/run/omashiki/llm-egress.sock"
  @isolated_host_base_url "http://127.0.0.1:8080"
  @isolated_egress_proxy "http://127.0.0.1:8081"
  @default_bootstrap_timeout_ms 10 * 60 * 1_000
  @socket_path Application.compile_env(:omashiki, :docker_socket_path, "/var/run/docker.sock")

  @default_resource_limits %{
    pids_limit: 256,
    # 2 GiB memory cap, swap matched (no swap allowed).
    memory_bytes: 2 * 1024 * 1024 * 1024,
    memory_swap_bytes: 2 * 1024 * 1024 * 1024,
    # 2 vCPU.
    nano_cpus: 2_000_000_000
  }

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Provisions one governed job attempt through the hardened Docker boundary."
  @impl true
  def provision_for_job(
        %Job{} = job,
        %Omashiki.Jobs.JobAttempt{} = attempt,
        environment,
        opts
      ) do
    GenServer.call(
      __MODULE__,
      {:provision_for_job, job, attempt, environment, opts},
      15 * 60 * 1_000
    )
  end

  @doc "Executes a validated argv list inside an existing container."
  @impl true
  def exec(container_id, argv, timeout_ms)
      when is_binary(container_id) and is_list(argv) and is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(__MODULE__, {:exec, container_id, argv, timeout_ms}, timeout_ms + 10_000)
  end

  @doc "Stops and removes a container by ID. Fire-and-forget."
  @impl true
  def destroy(sandbox_id) do
    GenServer.cast(__MODULE__, {:destroy, sandbox_id})
  end

  @doc "Lists and destroys Docker containers that no longer belong to a job."
  @impl true
  def cleanup_orphans do
    GenServer.call(__MODULE__, :cleanup_orphans, 30_000)
  end

  @doc """
  Returns the tail of the container's combined stdout/stderr as a single
  string. Best-effort diagnostic — callers should log/persist the output but
  not depend on a specific format. Stderr chunks are prefixed `[stderr] `.

  Opts:
    * `:tail` (integer, default 200) — how many trailing lines Docker should
      return. `:all` is also accepted.
  """
  @impl true
  def fetch_logs(sandbox_id, opts \\ []) when is_binary(sandbox_id) do
    GenServer.call(__MODULE__, {:fetch_logs, sandbox_id, opts}, 10_000)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    case docker_ping() do
      :ok ->
        Logger.info("[ContainerManager] Docker Engine API is reachable")
        {:ok, %{available: true}}

      {:error, reason} ->
        Logger.warning(
          "[ContainerManager] Docker not available: #{inspect(reason)}. Running in degraded mode."
        )

        {:ok, %{available: false}}
    end
  end

  @impl true
  def handle_call(:cleanup_orphans, _from, %{available: false} = state),
    do: {:reply, {:ok, []}, state}

  def handle_call(:cleanup_orphans, _from, state) do
    {:reply, do_cleanup_orphans(), state}
  end

  def handle_call(
        {:provision_for_job, _job, _attempt, _environment, _opts},
        _from,
        %{available: false} = state
      ) do
    {:reply, {:error, :docker_unavailable}, state}
  end

  def handle_call({:provision_for_job, job, attempt, environment, opts}, _from, state) do
    {:reply, do_provision_for_job(job, attempt, environment, opts), state}
  end

  def handle_call({:fetch_logs, _id, _opts}, _from, %{available: false} = state),
    do: {:reply, {:error, :docker_unavailable}, state}

  def handle_call({:fetch_logs, container_id, opts}, _from, state) do
    {:reply, do_fetch_logs(container_id, opts), state}
  end

  def handle_call({:exec, _container_id, _argv, _timeout_ms}, _from, %{available: false} = state),
    do: {:reply, {:error, :docker_unavailable}, state}

  def handle_call({:exec, container_id, argv, timeout_ms}, _from, state) do
    {:reply, do_exec_stream(container_id, argv, timeout_ms: timeout_ms), state}
  end

  @impl true
  def handle_cast({:destroy, _container_id}, %{available: false} = state), do: {:noreply, state}

  def handle_cast({:destroy, container_id}, state) do
    do_destroy(container_id)
    {:noreply, state}
  end

  # --- Provision ---

  defp do_provision_for_job(
         %Job{} = job,
         %Omashiki.Jobs.JobAttempt{} = attempt,
         environment,
         opts
       ) do
    worktree_path = Keyword.get(opts, :worktree_path, get_in(job.repository_snapshot, ["path"]))
    profile = Keyword.get(opts, :harness_profile) || Omashiki.Harnesses.profile(environment)
    credential = Keyword.get(opts, :credential) || credential_for_environment(environment)
    runtime_mount_defs = environment_mounts(environment)
    cache_groups = environment_cache_groups(environment)
    network_mode = network_mode(environment)
    job_scope = %{id: "job-#{attempt.id}"}

    opts =
      opts
      |> Keyword.put(:worktree_path, worktree_path)
      |> Keyword.put(:harness_profile, profile)
      |> Keyword.put(:job, job)
      |> Keyword.put(:credential, credential)
      |> Keyword.put(:environment, environment)
      |> Keyword.put(:runtime_mount_defs, runtime_mount_defs)
      |> Keyword.put(:cache_groups, cache_groups)
      |> Keyword.put(:resource_limits, environment_resources(environment))
      |> Keyword.put(:network_mode, network_mode)

    worktree_path = Keyword.fetch!(opts, :worktree_path)
    credential = Keyword.get(opts, :credential)
    profile = Keyword.get(opts, :harness_profile)
    launch_plan = profile.launch_plan
    protocol = transport_kind(launch_plan)

    host_port =
      case protocol do
        "http" -> Keyword.get(opts, :host_port) || pick_free_host_port()
        _ -> Keyword.get(opts, :host_port)
      end

    # Runtime delivery is admitted from the immutable job snapshot only.
    {repo_root, _subpath} = parent_repo_and_subpath(worktree_path)
    container_workdir = Path.expand(worktree_path)
    {host_uid, host_gid} = host_owner_ids(repo_root)

    runtime_mount_defs =
      Keyword.get(
        opts,
        :runtime_mount_defs,
        %{}
      )

    runtime_mounts = runtime_mount_binds(runtime_mount_defs)

    cache_groups =
      Keyword.get(
        opts,
        :cache_groups,
        []
      )

    started_at = System.monotonic_time(:millisecond)

    with_cache_lease(job_scope.id, cache_groups, fn ->
      cache_outcomes = cache_outcomes(cache_groups)

      result =
        with :ok <- validate_supply_chain_network(cache_groups),
             {:ok, cache_mounts} <- prepare_cache_mounts(cache_groups) do
          do_create_container(
            job_scope,
            opts,
            credential,
            profile,
            protocol,
            host_port,
            repo_root,
            container_workdir,
            host_uid,
            host_gid,
            runtime_mounts,
            cache_groups,
            cache_mounts,
            runtime_mount_defs
          )
        end

      record_cache_access(cache_outcomes, elapsed_ms(started_at))
      result
    end)
  end

  defp with_cache_lease(_owner, [], fun), do: invoke_provision(fun)

  defp with_cache_lease(owner, groups, fun) do
    case CacheMaintenance.acquire(groups, owner) do
      {:ok, _lease} ->
        result = invoke_provision(fun)

        case result do
          {:ok, _} ->
            result

          _ ->
            release_cache_owner(owner)
            result
        end

      {:error, reason} ->
        {:error, {:cache_lease, reason}}
    end
  end

  defp invoke_provision(fun) do
    fun.()
  rescue
    error -> {:error, {:provision_exception, error}}
  catch
    kind, reason -> {:error, {:provision_throw, kind, reason}}
  end

  defp cache_outcomes(groups) do
    groups
    |> Enum.flat_map(fn group ->
      case safe_cache_snapshot(group) do
        {:ok, snapshot} -> [{group.name, CacheSnapshot.outcome(snapshot)}]
        _ -> []
      end
    end)
  end

  defp safe_cache_snapshot(group) do
    CacheMaintenance.snapshot(group)
  rescue
    _ -> {:error, :cache_maintenance_unavailable}
  catch
    _, _ -> {:error, :cache_maintenance_unavailable}
  end

  defp record_cache_access(outcomes, duration_ms) do
    Enum.each(outcomes, fn {name, outcome} ->
      case CacheMaintenance.record_access(name, outcome, duration_ms) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("[ContainerManager] Cache access recording failed: #{inspect(reason)}")

        other ->
          Logger.warning("[ContainerManager] Cache access recording returned #{inspect(other)}")
      end
    end)
  rescue
    error ->
      Logger.warning("[ContainerManager] Cache access recording crashed: #{inspect(error)}")
  catch
    _, reason ->
      Logger.warning("[ContainerManager] Cache access recording threw: #{inspect(reason)}")
  end

  defp release_cache_owner(owner) do
    _ = CacheMaintenance.release_owner(owner)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp elapsed_ms(started_at),
    do: max(System.monotonic_time(:millisecond) - started_at, 0)

  defp do_create_container(
         group,
         opts,
         credential,
         profile,
         protocol,
         host_port,
         repo_root,
         container_workdir,
         host_uid,
         host_gid,
         runtime_mounts,
         cache_groups,
         cache_mounts,
         runtime_mount_defs
       ) do
    runtime_job = Keyword.get(opts, :job)
    supply = supply_chain_delivery(group.id, runtime_job, cache_groups, host_uid, host_gid)

    context = %Omashiki.Harness.Context{
      job: runtime_job,
      credential: credential,
      environment: Keyword.get(opts, :environment, %{}),
      profile: profile,
      runtime_mounts: runtime_mount_defs,
      host_base_url: isolated_host_base_url(supply.env)
    }

    adapter = Omashiki.Harnesses.adapter(profile)

    with {:ok, launch} <- adapter.prepare(profile, context) do
      secret = launch.secret || %{}
      secret_payload = Map.get(secret, "contents")
      secret_target = Map.get(secret, "target")
      secret_host_path = if is_binary(secret_payload), do: secret_host_path_for(group.id)
      egress = harness_egress_delivery(launch.llm_egress, supply.env, runtime_job)

      try do
        if is_binary(secret_payload) do
          :ok = write_secret_host_file(secret_host_path, secret_payload, host_uid, host_gid)
        end

        Enum.each(supply.files, fn {path, contents} ->
          :ok = write_secret_host_file(path, contents, host_uid, host_gid)
        end)

        container_config =
          build_container_config(group,
            worktree_path: container_workdir,
            repo_root: repo_root,
            host_port: host_port,
            credential: credential,
            host_uid: host_uid,
            host_gid: host_gid,
            secret_host_path: secret_host_path,
            secret_target: secret_target,
            harness_profile: profile,
            launch_plan: launch,
            job: runtime_job,
            environment: Keyword.get(opts, :environment, %{}),
            cache_groups: cache_groups,
            resource_limits: Keyword.get(opts, :resource_limits),
            network_mode: Keyword.get(opts, :network_mode),
            harness_env: launch.environment,
            llm_egress: launch.llm_egress,
            supply_chain_env: supply.env ++ egress.env,
            supply_chain_labels: Map.merge(supply.labels, egress.labels),
            extra_binds:
              runtime_mounts ++ Enum.map(cache_mounts, & &1.bind) ++ supply.binds ++ egress.binds
          )

        case docker_post("/containers/create", container_config) do
          {:ok, %{"Id" => container_id}} ->
            case finalize_provision(
                   container_id,
                   host_port,
                   protocol,
                   launch,
                   container_workdir,
                   cache_groups,
                   runtime_job && runtime_job.id
                 ) do
              {:ok, info} ->
                info =
                  info
                  |> Map.put(:llm_egress, launch.llm_egress)
                  |> Map.put(:worktree_path, container_workdir)
                  |> Map.put(:cache_groups, Enum.map(cache_mounts, & &1.name))

                {:ok, info}

              err ->
                err
            end

          {:error, reason} ->
            Logger.error("[ContainerManager] Provision failed at create: #{inspect(reason)}")
            {:error, reason}
        end
      after
        if is_binary(secret_host_path), do: File.rm(secret_host_path)
        Enum.each(supply.files, fn {path, _contents} -> File.rm(path) end)
      end
    end
  end

  @doc false
  def harness_egress_delivery(:engine, supply_env),
    do: harness_egress_delivery(:engine, supply_env, nil)

  def harness_egress_delivery(llm_egress, supply_env),
    do: harness_egress_delivery(llm_egress, supply_env, nil)

  def harness_egress_delivery(:engine, supply_env, runtime_job) when is_list(supply_env) do
    isolated? = Enum.any?(supply_env, &String.starts_with?(&1, "OMASHIKI_HOST_SOCKET="))

    if isolated? do
      hosts = Omashiki.LlmEgress.Proxy.hosts()

      if hosts == [] do
        raise ArgumentError,
              "isolated engine egress requires OMASHIKI_LLM_EGRESS_HOSTS"
      end

      token_env =
        case runtime_job do
          %Job{} = job ->
            case Omashiki.Runtime.Claims.issue("egress", job, %{}) do
              {:ok, token} -> ["OMASHIKI_LLM_EGRESS_TOKEN=#{token}"]
              _ -> raise ArgumentError, "isolated engine egress requires an active job"
            end

          _ ->
            []
        end

      %{
        env:
          [
            "OMASHIKI_LLM_EGRESS_SOCKET=#{@llm_egress_socket}",
            "HTTPS_PROXY=#{@isolated_egress_proxy}",
            "HTTP_PROXY=#{@isolated_egress_proxy}",
            "NO_PROXY=localhost,127.0.0.1"
          ] ++ token_env,
        binds: ["#{Omashiki.LlmEgress.Proxy.path()}:#{@llm_egress_socket}:rw"],
        labels: %{"omashiki.llm_egress" => "restricted"}
      }
    else
      %{env: [], binds: [], labels: %{}}
    end
  end

  def harness_egress_delivery(_llm_egress, _supply_env, _runtime_job),
    do: %{env: [], binds: [], labels: %{}}

  @doc false
  def supply_chain_delivery(_group_id, _job, [], _uid, _gid),
    do: %{env: [], labels: %{}, binds: [], files: []}

  def supply_chain_delivery(group_id, %Job{} = job, cache_groups, _uid, _gid) do
    policies = Enum.filter(cache_groups, &match?(%{policy: %Policy{}}, &1))

    case policies do
      [] ->
        %{env: [], labels: %{}, binds: [], files: []}

      [_first, _second | _] ->
        raise ArgumentError, "only one supply-chain policy may be attached to a runtime"

      [group | _] ->
        policy = group.policy

        token =
          Omashiki.SupplyChain.Proxy.sign_token(
            job.id,
            job.user_id,
            job.environment_digest,
            group.name,
            policy.digest || Policy.digest(policy)
          )

        isolated? = policy.mode == :allowlist
        proxy_opts = if isolated?, do: [base_url: @isolated_host_base_url], else: []
        npm = Proxy.url(group.name, "npm", token, proxy_opts)
        cargo = Proxy.url(group.name, "cargo", token, proxy_opts)
        go = Proxy.url(group.name, "go", token, proxy_opts)
        config_path = generated_cargo_config_path(group_id)
        config = cargo_config(cargo, token)
        cargo_home = Map.get(group.env || %{}, "CARGO_HOME", "#{@agent_home}/.cargo")

        socket_delivery =
          if isolated? do
            %{
              env: ["OMASHIKI_HOST_SOCKET=#{@host_socket}"],
              binds: ["#{SocketBridge.path()}:#{@host_socket}:rw"]
            }
          else
            %{env: [], binds: []}
          end

        %{
          env:
            [
              "npm_config_registry=#{npm}",
              "GOPROXY=#{go}",
              "GOSUMDB=off",
              "CARGO_HOME=#{cargo_home}",
              "CARGO_REGISTRIES_OMASHIKI_TOKEN=#{token}"
            ] ++ socket_delivery.env,
          labels: %{
            "omashiki.supply_chain" => "true",
            "omashiki.supply_chain_policy" => policy.digest || Policy.digest(policy),
            "omashiki.supply_chain_cache_group" => group.name
          },
          binds: ["#{config_path}:#{cargo_home}/config.toml:ro"] ++ socket_delivery.binds,
          files: [{config_path, config}]
        }
    end
  end

  @doc false
  def generated_cargo_config_path(group_id) do
    base = if File.dir?("/dev/shm"), do: "/dev/shm", else: System.tmp_dir!()

    Path.join(
      base,
      "omashiki-cargo-#{group_id}-#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}.toml"
    )
  end

  @doc false
  def cargo_config(cargo_url, _token) when is_binary(cargo_url) do
    cargo_url = cargo_url |> String.split("?", parts: 2) |> hd()

    "[source.crates-io]\nreplace-with = \"omashiki\"\n\n" <>
      "[source.omashiki]\nregistry = \"sparse+#{cargo_url}\"\n\n" <>
      "[net]\nretry = 0\n"
  end

  defp prepare_cache_mounts(cache_groups) do
    Enum.reduce_while(cache_groups, {:ok, []}, fn group, {:ok, mounts} ->
      host = expand_host_path(Omashiki.Runtimes.CacheGroup.host_path(group))

      case ensure_cache_directory(host) do
        :ok ->
          mount = %{
            name: group.name,
            host: host,
            bind: "#{host}:/omashiki-cache/#{group.name}"
          }

          {:cont, {:ok, [mount | mounts]}}

        {:error, reason} ->
          Logger.error(
            "[ContainerManager] Cannot create cache group #{group.name} at #{host}: #{inspect(reason)}"
          )

          {:halt, {:error, {:cache_directory, group.name, reason}}}
      end
    end)
    |> case do
      {:ok, mounts} -> {:ok, Enum.reverse(mounts)}
      error -> error
    end
  end

  @doc false
  def ensure_cache_directory(host) do
    with :ok <- reject_symlink_components(host),
         :ok <- File.mkdir_p(host),
         :ok <- reject_symlink_components(host) do
      :ok
    end
  end

  defp reject_symlink_components(path) do
    path
    |> Path.split()
    |> Enum.reduce_while("/", fn component, parent ->
      current = if component == "/", do: "/", else: Path.join(parent, component)

      case File.lstat(current) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :symlink}}
        {:ok, _} -> {:cont, current}
        {:error, :enoent} -> {:cont, current}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      path when is_binary(path) -> :ok
      error -> error
    end
  end

  @doc false
  def cache_group_binds(cache_groups) when is_list(cache_groups) do
    Enum.map(cache_groups, fn group ->
      "#{expand_host_path(Omashiki.Runtimes.CacheGroup.host_path(group))}:/omashiki-cache/#{group.name}"
    end)
  end

  defp transport_kind(%{transport: %{kind: kind}}), do: normalize_transport_kind(kind)
  defp transport_kind(%{transport: %{"kind" => kind}}), do: normalize_transport_kind(kind)
  defp transport_kind(%{"transport" => %{"kind" => kind}}), do: normalize_transport_kind(kind)
  defp transport_kind(_), do: "http"

  defp normalize_transport_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp normalize_transport_kind(kind) when is_binary(kind), do: kind
  defp normalize_transport_kind(_), do: "http"

  defp environment_mounts(environment) do
    environment
    |> Map.get(:mounts, Map.get(environment, "mounts", []))
    |> Enum.map(fn mount ->
      {Map.get(mount, :source, Map.get(mount, "source")),
       Map.get(mount, :target, Map.get(mount, "target")),
       Map.get(mount, :read_only, Map.get(mount, "read_only", true))}
    end)
  end

  defp environment_cache_groups(environment) do
    environment
    |> Map.get(:caches, Map.get(environment, "caches", []))
    |> Enum.map(fn cache ->
      %Omashiki.Runtimes.CacheGroup{
        name: Map.get(cache, :name, Map.get(cache, "name")),
        host: Map.get(cache, :host, Map.get(cache, "host")),
        env: Map.get(cache, :env, Map.get(cache, "env", %{})),
        max_size_mb: Map.get(cache, :max_size_mb, Map.get(cache, "max_size_mb")),
        policy: environment_policy(Map.get(cache, :policy, Map.get(cache, "policy")))
      }
    end)
  end

  defp credential_for_environment(environment) do
    environment
    |> Map.get(:credentials, Map.get(environment, "credentials", []))
    |> List.wrap()
    |> List.first()
    |> case do
      %{name: name} when is_binary(name) -> Omashiki.Config.get_credential(name)
      %{"name" => name} when is_binary(name) -> Omashiki.Config.get_credential(name)
      _ -> nil
    end
  end

  defp environment_policy(nil), do: nil
  defp environment_policy(%Omashiki.SupplyChain.Policy{} = policy), do: policy

  defp environment_policy(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.drop([:digest, :package_registries, "digest", "package_registries"])

    case Omashiki.SupplyChain.Policy.parse(attrs, where: "job environment cache policy") do
      {:ok, policy} -> policy
      {:error, reason} -> raise ArgumentError, to_string(reason)
    end
  end

  defp environment_policy(other),
    do: raise(ArgumentError, "invalid job environment cache policy #{inspect(other)}")

  defp environment_resources(environment) do
    resources = Map.get(environment, :resources, Map.get(environment, "resources", %{}))

    %{
      nano_cpus: Map.get(resources, :nano_cpus, Map.get(resources, "nano_cpus")),
      memory_bytes: Map.get(resources, :memory_bytes, Map.get(resources, "memory_bytes")),
      memory_swap_bytes:
        Map.get(resources, :memory_swap_bytes, Map.get(resources, "memory_swap_bytes")),
      pids_limit: Map.get(resources, :pids_limit, Map.get(resources, "pids_limit"))
    }
  end

  defp network_mode(environment) do
    case Map.get(environment, :network, Map.get(environment, "network", "none")) do
      "host" ->
        "host"

      "none" ->
        "none"

      "restricted" ->
        Application.get_env(:omashiki, :restricted_agent_network, agent_network_mode() || "none")

      _ ->
        "none"
    end
  end

  defp runtime_mount_binds(mounts) do
    mounts
    |> Enum.map(fn {host, dest, read_only} ->
      suffix = if read_only, do: ":ro", else: ""
      "#{expand_host_path(host)}:#{resolve_container_path(dest)}#{suffix}"
    end)
  end

  defp runtime_of(%{runtime: %Omashiki.Runtimes.Runtime{} = runtime}), do: runtime

  defp runtime_of(%{runtime: %{"kind" => kind, "config" => config}}),
    do: %Omashiki.Runtimes.Runtime{kind: kind, config: config, key: nil, status: "active"}

  defp runtime_of(%{runtime: runtime}) when not is_nil(runtime), do: runtime

  defp runtime_of(_), do: nil

  defp expand_host_path("~/" <> rest), do: Path.join(System.user_home!(), rest)
  defp expand_host_path("~"), do: System.user_home!()
  defp expand_host_path(path) when is_binary(path), do: path

  # The canonical harness HOME is tmpfs-backed; keep mount resolution in sync.
  defp resolve_container_path("$HOME" <> rest), do: @agent_home <> rest
  defp resolve_container_path(path) when is_binary(path), do: path

  defp finalize_provision(
         container_id,
         host_port,
         protocol,
         launch_plan,
         worktree_path,
         cache_groups,
         task_id
       )
       when protocol in ["http", "cli"] do
    started_at = System.monotonic_time(:millisecond)

    {result, bootstrap_duration_ms} =
      case docker_post_no_body("/containers/#{container_id}/start") do
        :ok ->
          with :ok <- verify_supply_chain_proxy(container_id, cache_groups),
               :ok <- run_supply_chain_preflight(worktree_path, cache_groups, task_id) do
            bootstrap_started_at = System.monotonic_time(:millisecond)
            bootstrap_result = run_launch_startup(container_id, launch_plan)
            bootstrap_duration_ms = elapsed_ms(bootstrap_started_at)

            result =
              with :ok <- bootstrap_result,
                   {:ok, info} <-
                     finalize_transport(protocol, container_id, host_port, launch_plan) do
                {:ok, info}
              end

            {result, bootstrap_duration_ms}
          else
            {:error, reason} -> {{:error, reason}, 0}
          end

        {:error, reason} ->
          {{:error, reason}, 0}
      end

    duration_ms = elapsed_ms(started_at)
    outcome = if match?({:ok, _}, result), do: "ok", else: "error"

    :telemetry.execute(
      [:omashiki, :container, :provision],
      %{duration_ms: duration_ms},
      %{outcome: outcome}
    )

    :telemetry.execute(
      [:omashiki, :container, :bootstrap],
      %{duration_ms: bootstrap_duration_ms},
      %{outcome: outcome}
    )

    case result do
      {:ok, info} ->
        {:ok,
         info
         |> Map.put(:provision_duration_ms, duration_ms)
         |> Map.put(:bootstrap_duration_ms, bootstrap_duration_ms)}

      {:error, reason} = err ->
        logs =
          case do_fetch_logs(container_id, tail: 100) do
            {:ok, output} -> String.trim(output)
            {:error, log_reason} -> "<logs unavailable: #{inspect(log_reason)}>"
          end

        Logger.error(
          "[ContainerManager] Provision failed for container #{container_id}: #{inspect(reason)}\n#{logs}"
        )

        do_destroy(container_id)
        err
    end
  rescue
    error ->
      :telemetry.execute(
        [:omashiki, :container, :provision],
        %{duration_ms: 0},
        %{outcome: "error"}
      )

      :telemetry.execute(
        [:omashiki, :container, :bootstrap],
        %{duration_ms: 0},
        %{outcome: "error"}
      )

      do_destroy(container_id)
      {:error, {:provision_exception, error}}
  catch
    kind, reason ->
      do_destroy(container_id)
      {:error, {:provision_throw, kind, reason}}
  end

  defp finalize_provision(
         _container_id,
         _host_port,
         _protocol,
         _profile,
         _worktree_path,
         _cache_groups,
         _task_id
       ),
       do: {:error, :unsupported_agent_protocol}

  defp run_supply_chain_preflight(_root, [], _job_id), do: :ok

  defp run_supply_chain_preflight(root, cache_groups, job_id) do
    {repo_root, _subpath} = parent_repo_and_subpath(root)

    Enum.reduce_while(cache_groups, :ok, fn
      %{policy: nil}, :ok ->
        {:cont, :ok}

      %{name: name, policy: %Policy{} = policy}, :ok ->
        case Preflight.run(root, policy,
               job_id: job_id,
               cache_group: name,
               mounted_roots: [repo_root]
             ) do
          {:ok, _report} -> {:cont, :ok}
          {:error, report} -> {:halt, {:error, {:supply_chain_preflight, report}}}
        end

      _, :ok ->
        {:halt, {:error, :invalid_supply_chain_policy}}
    end)
  end

  defp validate_supply_chain_network(cache_groups) do
    if Enum.any?(cache_groups, &match?(%{policy: %Policy{mode: :allowlist}}, &1)) do
      mode = Application.get_env(:omashiki, :agent_network_mode)
      network = Application.get_env(:omashiki, :supply_chain_network)

      cond do
        mode in [nil, "", "host", "bridge", "default"] ->
          {:error, :supply_chain_requires_internal_network}

        not is_binary(network) or network == "" ->
          {:error, :supply_chain_network_not_configured}

        mode != network ->
          {:error, {:supply_chain_network_mismatch, network}}

        true ->
          verify_internal_network(network)
      end
    else
      :ok
    end
  end

  defp verify_internal_network(network) do
    case docker_get("/networks/#{URI.encode_www_form(network)}") do
      {:ok, payload} ->
        if internal_network?(payload),
          do: :ok,
          else: {:error, {:supply_chain_network_not_internal, network}}

      {:error, reason} ->
        {:error, {:supply_chain_network_unavailable, network, reason}}
    end
  end

  @doc false
  def internal_network?(payload) when is_map(payload) do
    Map.get(payload, "Internal") == true or Map.get(payload, :Internal) == true
  end

  def internal_network?(_), do: false

  defp verify_supply_chain_proxy(container_id, cache_groups) do
    if Enum.any?(cache_groups, &match?(%{policy: %Policy{mode: :allowlist}}, &1)) do
      health_url = @isolated_host_base_url <> "/api/v1/health"
      deadline = System.monotonic_time(:millisecond) + 5_000
      do_verify_supply_chain_proxy(container_id, health_url, deadline)
    else
      :ok
    end
  end

  defp do_verify_supply_chain_proxy(container_id, health_url, deadline) do
    result =
      case do_exec_stream(
             container_id,
             ["curl", "--fail", "--silent", "--show-error", "--max-time", "1", health_url],
             timeout_ms: 3_000
           ) do
        {:ok, %{exit_code: 0}} ->
          :ok

        {:ok, %{exit_code: code, stdout: output}} ->
          {:error, {:supply_chain_proxy_unreachable, code, output}}

        {:error, reason} ->
          {:error, {:supply_chain_proxy_unreachable, reason}}
      end

    if result != :ok and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(100)
      do_verify_supply_chain_proxy(container_id, health_url, deadline)
    else
      result
    end
  end

  defp run_launch_startup(container_id, launch_plan) do
    startup = launch_plan_value(launch_plan, :startup)

    command =
      startup_value(startup, :argv) || Omashiki.Runtimes.bootstrap(runtime_of_launch(launch_plan))

    case command do
      nil ->
        :ok

      command when is_list(command) ->
        timeout_ms =
          startup_value(startup, :timeout_ms) ||
            Omashiki.Runtimes.bootstrap_timeout_ms(runtime_of_launch(launch_plan)) ||
            @default_bootstrap_timeout_ms

        case do_exec_stream(container_id, command, timeout_ms: timeout_ms) do
          {:ok, %{exit_code: 0}} -> :ok
          {:ok, %{exit_code: code, stdout: output}} -> {:error, {:bootstrap_failed, code, output}}
          {:error, reason} -> {:error, {:bootstrap_exec, reason}}
        end
    end
  end

  defp finalize_transport("http", container_id, host_port, launch_plan) do
    with {:ok, {host, port}} <-
           harness_endpoint(container_id, host_port, transport_port(launch_plan)),
         :ok <-
           wait_for_harness(
             host,
             port,
             readiness_path(launch_plan),
             readiness_timeout(launch_plan)
           ) do
      {:ok,
       %{
         sandbox_id: container_id,
         host: host,
         port: port,
         transport: launch_plan.transport
       }}
    end
  end

  defp finalize_transport("cli", container_id, _host_port, launch_plan) do
    case readiness_command(launch_plan) do
      nil ->
        {:ok, %{sandbox_id: container_id, transport: launch_plan.transport}}

      {argv, timeout_ms} ->
        deadline = System.monotonic_time(:millisecond) + timeout_ms

        case wait_for_exec_readiness(container_id, argv, deadline) do
          :ok -> {:ok, %{sandbox_id: container_id, transport: launch_plan.transport}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp wait_for_exec_readiness(container_id, argv, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 1)

    result =
      case do_exec_stream(container_id, argv, timeout_ms: remaining) do
        {:ok, %{exit_code: 0}} ->
          :ok

        {:ok, %{exit_code: code, stdout: output}} ->
          {:error, {:harness_readiness_failed, code, output}}

        {:error, reason} ->
          {:error, {:harness_readiness_failed, reason}}
      end

    if result != :ok and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(100)
      wait_for_exec_readiness(container_id, argv, deadline)
    else
      result
    end
  end

  defp readiness_command(launch_plan) do
    readiness = Map.get(launch_plan, :readiness, Map.get(launch_plan, "readiness"))

    case readiness do
      %{"kind" => "exec", "argv" => argv} when is_list(argv) ->
        {argv, Map.get(readiness, "timeout_ms", 10_000)}

      %{kind: kind, argv: argv} = config when kind in ["exec", :exec] and is_list(argv) ->
        {argv, Map.get(config, :timeout_ms, 10_000)}

      _ ->
        nil
    end
  end

  defp runtime_of_launch(%{runtime: runtime}), do: runtime_of(%{runtime: runtime})
  defp runtime_of_launch(%{"runtime" => runtime}), do: runtime_of(%{runtime: runtime})
  defp runtime_of_launch(_), do: nil

  defp launch_plan_value(%{startup: value}, :startup), do: value
  defp launch_plan_value(%{"startup" => value}, :startup), do: value
  defp launch_plan_value(_, _), do: nil

  defp startup_value(%{argv: value}, :argv), do: value
  defp startup_value(%{"argv" => value}, :argv), do: value
  defp startup_value(%{timeout_ms: value}, :timeout_ms), do: value
  defp startup_value(%{"timeout_ms" => value}, :timeout_ms), do: value
  defp startup_value(_, _), do: nil

  defp transport_port(%{transport: transport}),
    do: Map.get(transport, :port, Map.get(transport, "port"))

  defp transport_port(%{"transport" => transport}),
    do: Map.get(transport, "port", Map.get(transport, :port))

  defp transport_port(_), do: nil

  defp readiness_path(%{readiness: readiness}),
    do: Map.get(readiness, :path, Map.get(readiness, "path", "/"))

  defp readiness_path(%{"readiness" => readiness}),
    do: Map.get(readiness, "path", Map.get(readiness, :path, "/"))

  defp readiness_path(_), do: "/"

  defp readiness_timeout(%{readiness: readiness}),
    do: Map.get(readiness, :timeout_ms, Map.get(readiness, "timeout_ms", 60_000))

  defp readiness_timeout(%{"readiness" => readiness}),
    do: Map.get(readiness, "timeout_ms", Map.get(readiness, :timeout_ms, 60_000))

  defp readiness_timeout(_), do: 60_000

  @doc false
  def secret_host_path_for(group_id) do
    base = if File.dir?("/dev/shm"), do: "/dev/shm", else: System.tmp_dir!()
    nonce = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    Path.join(base, "omashiki-auth-#{group_id}-#{nonce}.json")
  end

  defp write_secret_host_file(path, content, uid, gid) do
    File.open!(path, [:write, :binary, :exclusive], fn file ->
      File.chmod!(path, 0o600)
      IO.binwrite(file, content)
    end)

    # Best-effort chown so the file is readable by the runtime UID inside
    # the container. May silently no-op when the orchestrator does not have
    # CAP_CHOWN (e.g. rootless docker setups where the file is already
    # owned by the host user); that is fine because the host UID we use
    # is the orchestrator's own UID by default.
    _ = System.cmd("chown", ["#{uid}:#{gid}", path], stderr_to_stdout: true)
    :ok
  end

  @doc """
  Builds the full Docker container-create payload for a job attempt.
  Pure function: receives everything it needs as opts and returns a map.
  Exposed (not `defp`) so the host-config shape can be unit-tested without
  touching the Docker API.

  Required opts:
    * `:worktree_path` (string, absolute) — agent's WORKDIR.
    * `:repo_root` (string, absolute) — parent repo root used as RO bind.
    * `:host_port` (integer) — host TCP port to map to the container's :4096.
    * `:credential` — optional credential passed to the harness adapter.
    * `:host_uid`, `:host_gid` (integers) — runtime UID/GID; ensures files
      written by the agent inside the bind mounts are owned by the host
      user, regardless of the image's default `USER`.
  """
  def build_container_config(job_scope, opts) do
    worktree_path = Keyword.fetch!(opts, :worktree_path)
    repo_root = Keyword.fetch!(opts, :repo_root)
    host_port = Keyword.get(opts, :host_port)
    credential = Keyword.get(opts, :credential)
    host_uid = Keyword.fetch!(opts, :host_uid)
    host_gid = Keyword.fetch!(opts, :host_gid)
    secret_host_path = Keyword.get(opts, :secret_host_path)
    profile = Keyword.fetch!(opts, :harness_profile)
    launch_plan = Keyword.fetch!(opts, :launch_plan)
    job = Keyword.get(opts, :job)
    protocol = transport_kind(launch_plan)
    image = image_of(profile)
    internal_port = transport_port(launch_plan)

    cache_groups = Keyword.get(opts, :cache_groups, [])
    supply_chain_env = Keyword.get(opts, :supply_chain_env, [])
    network_mode = Keyword.get(opts, :network_mode, agent_network_mode())

    harness_env =
      Keyword.get_lazy(opts, :harness_env, fn ->
        host_base_url = isolated_host_base_url(supply_chain_env)

        context = %Omashiki.Harness.Context{
          job: job,
          credential: credential,
          environment: Keyword.get(opts, :environment, %{}),
          profile: profile,
          host_base_url: host_base_url
        }

        {:ok, prepared} = Omashiki.Harnesses.adapter(profile).prepare(profile, context)
        prepared.environment
      end)

    env =
      harness_env
      |> merge_cache_env(cache_groups)
      |> merge_env_overrides(supply_chain_env)

    env =
      if network_mode == "host" do
        transport_port_environment(launch_plan, host_port) ++ env
      else
        env
      end

    labels =
      %{
        @container_label => "true",
        "omashiki.job_scope_id" => job_scope.id,
        "omashiki.protocol" => protocol,
        "omashiki.runtime" => runtime_kind_of(profile)
      }
      |> maybe_put_cache_label(cache_groups)
      |> Map.merge(Keyword.get(opts, :supply_chain_labels, %{}))

    base = %{
      "Image" => image,
      "Env" => env,
      "User" => "#{host_uid}:#{host_gid}",
      "Labels" => labels,
      "HostConfig" =>
        build_host_config(repo_root, worktree_path, host_port, host_uid, host_gid,
          secret_host_path: secret_host_path,
          secret_target: Keyword.get(opts, :secret_target),
          protocol: protocol,
          gateway_host: true,
          network_mode: network_mode,
          resource_limits: Keyword.get(opts, :resource_limits),
          extra_binds: Keyword.get(opts, :extra_binds, []),
          internal_port: internal_port
        ),
      "WorkingDir" => worktree_path
    }

    case network_mode do
      "host" ->
        base

      _ when is_integer(internal_port) ->
        Map.put(base, "ExposedPorts", %{"#{internal_port}/tcp" => %{}})

      _ ->
        base
    end
  end

  defp runtime_kind_of(%{runtime: %{kind: kind}}) when is_binary(kind), do: kind
  defp runtime_kind_of(%{runtime: %{kind: kind}}) when is_atom(kind), do: to_string(kind)
  defp runtime_kind_of(%{"runtime" => %{"kind" => kind}}), do: to_string(kind)

  defp runtime_kind_of(_), do: "unknown"

  defp image_of(profile) do
    case runtime_image(profile) do
      image when is_binary(image) and image != "" ->
        image

      _ ->
        raise ArgumentError,
              "harness profile must provide a Docker runtime image"
    end
  end

  defp transport_port_environment(%{transport: transport}, host_port),
    do:
      port_environment(
        Map.get(transport, :port_environment, Map.get(transport, "port_environment", [])),
        host_port
      )

  defp transport_port_environment(%{"transport" => transport}, host_port),
    do:
      port_environment(
        Map.get(transport, "port_environment", Map.get(transport, :port_environment, [])),
        host_port
      )

  defp transport_port_environment(_, _), do: []

  defp port_environment(entries, host_port) when is_list(entries) do
    Enum.map(entries, fn entry ->
      String.replace(entry, "${PORT}", Integer.to_string(host_port))
    end)
  end

  defp port_environment(_, _), do: []

  defp runtime_image(%{runtime: runtime}) when not is_nil(runtime) do
    Omashiki.Runtimes.docker_image(runtime)
  end

  defp runtime_image(_), do: nil

  defp isolated_host_base_url(env) do
    if Enum.any?(env, &String.starts_with?(&1, "OMASHIKI_HOST_SOCKET=")),
      do: @isolated_host_base_url,
      else: nil
  end

  @doc false
  def merge_cache_env(base, cache_groups) when is_list(base) and is_list(cache_groups) do
    existing =
      MapSet.new(base, fn entry ->
        entry |> String.split("=", parts: 2) |> hd()
      end)

    {entries, _keys} =
      Enum.reduce(cache_groups, {base, existing}, fn group, {entries, keys} ->
        Enum.reduce(group.env || %{}, {entries, keys}, fn {key, value}, {acc, seen} ->
          key = to_string(key)

          if MapSet.member?(seen, key) do
            Logger.warning(
              "[ContainerManager] Cache env collision for #{key}; keeping the first value"
            )

            {acc, seen}
          else
            {acc ++ ["#{key}=#{value}"], MapSet.put(seen, key)}
          end
        end)
      end)

    entries
  end

  @doc false
  def merge_env_overrides(base, overrides) when is_list(base) and is_list(overrides) do
    override_keys =
      MapSet.new(overrides, fn entry -> entry |> String.split("=", parts: 2) |> hd() end)

    Enum.reject(base, fn entry ->
      key = entry |> String.split("=", parts: 2) |> hd()
      MapSet.member?(override_keys, key)
    end) ++ overrides
  end

  defp maybe_put_cache_label(labels, []), do: labels

  defp maybe_put_cache_label(labels, groups) do
    Map.put(labels, "omashiki.cache_groups", Enum.map_join(groups, ",", & &1.name))
  end

  # Poll the adapter's readiness endpoint before exposing the engine client.
  defp wait_for_harness(host, port, path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_harness(host, port, path, deadline)
  end

  defp do_wait_for_harness(host, port, path, deadline) do
    cond do
      System.monotonic_time(:millisecond) > deadline ->
        {:error, :harness_not_ready}

      probe_harness(host, port, path) == :ok ->
        :ok

      true ->
        Process.sleep(250)
        do_wait_for_harness(host, port, path, deadline)
    end
  end

  defp probe_harness(host, port, path) do
    case Mint.HTTP.connect(:http, host, port, mode: :passive, transport_opts: [timeout: 1_000]) do
      {:ok, conn} ->
        case Mint.HTTP.request(conn, "GET", path, [], "") do
          {:ok, conn, _ref} ->
            result =
              case Mint.HTTP.recv(conn, 0, 1_500) do
                {:ok, _conn, responses} ->
                  if Enum.any?(responses, &match?({:status, _, status} when status == 200, &1)),
                    do: :ok,
                    else: :pending

                _ ->
                  :pending
              end

            Mint.HTTP.close(conn)
            result

          {:error, conn, _} ->
            Mint.HTTP.close(conn)
            :pending
        end

      _ ->
        :pending
    end
  end

  defp do_fetch_logs(container_id, opts) do
    tail =
      case Keyword.get(opts, :tail, 200) do
        :all -> "all"
        n when is_integer(n) and n > 0 -> Integer.to_string(n)
        _ -> "200"
      end

    query = "?stdout=1&stderr=1&tail=#{tail}&timestamps=0&follow=0"

    case mint_request("GET", "/containers/#{container_id}/logs#{query}", [], nil) do
      {:ok, %{status: status, body: body}} when status in [200, 101] ->
        {:ok, demux_docker_stream(body)}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Docker's logs endpoint returns a multiplexed stream for non-TTY containers:
  # [stream_type:1][padding:3][length:4-BE][payload:length] repeated. We strip
  # frames and tag stderr chunks with a `[stderr] ` prefix so callers get a
  # single readable string. If the buffer doesn't look multiplexed (TTY mode
  # or short body), we return it verbatim.
  @doc false
  def demux_docker_stream(<<>>), do: ""

  def demux_docker_stream(buf) when is_binary(buf) do
    case do_demux(buf, []) do
      {:ok, parts} -> parts |> Enum.reverse() |> IO.iodata_to_binary()
      :not_muxed -> buf
    end
  end

  defp do_demux(<<>>, acc), do: {:ok, acc}

  defp do_demux(<<type, 0, 0, 0, len::32-big, rest::binary>>, acc)
       when type in [0, 1, 2] and byte_size(rest) >= len do
    <<chunk::binary-size(len), tail::binary>> = rest
    prefix = if type == 2, do: "[stderr] ", else: ""
    do_demux(tail, [[prefix, chunk] | acc])
  end

  defp do_demux(_buf, []), do: :not_muxed
  defp do_demux(buf, acc), do: {:ok, [buf | acc]}

  defp do_destroy(container_id), do: do_destroy(container_id, nil)

  defp do_destroy(container_id, container) do
    job_scope_id =
      job_scope_id_from_container(container) || inspect_container_job_scope_id(container_id)

    try do
      case docker_post_no_body("/containers/#{container_id}/stop?t=#{@stop_timeout}") do
        :ok ->
          :ok

        {:error, %{"message" => msg}} when is_binary(msg) ->
          Logger.debug("[ContainerManager] Stop: #{msg}")

        {:error, :not_found} ->
          :ok

        {:error, reason} ->
          Logger.warning("[ContainerManager] Stop failed: #{inspect(reason)}")
      end

      case docker_delete("/containers/#{container_id}") do
        :ok -> Logger.info("[ContainerManager] Container #{container_id} removed")
        {:error, :not_found} -> :ok
        {:error, reason} -> Logger.warning("[ContainerManager] Remove failed: #{inspect(reason)}")
      end
    after
      if is_binary(job_scope_id), do: release_cache_owner(job_scope_id)
    end
  end

  defp inspect_container_job_scope_id(container_id) do
    case docker_get("/containers/#{container_id}/json") do
      {:ok, container} -> job_scope_id_from_container(container)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp do_cleanup_orphans do
    filter = Jason.encode!(%{"label" => ["#{@container_label}=true"]})

    case docker_get("/containers/json?all=true&filters=#{URI.encode_www_form(filter)}") do
      {:ok, containers} when is_list(containers) ->
        active_ids = active_job_scope_ids()

        orphans = Enum.filter(containers, &(orphan_status(&1, active_ids) == :orphan))

        Enum.each(orphans, fn %{"Id" => id} = container -> do_destroy(id, container) end)

        {:ok, Enum.map(orphans, & &1["Id"])}

      err ->
        err
    end
  end

  defp active_job_scope_ids do
    import Ecto.Query

    Omashiki.Repo.all(
      from(attempt in Omashiki.Jobs.JobAttempt,
        where: attempt.status in ["provisioning", "running"],
        select: attempt.id
      )
    )
    |> Enum.map(&"job-#{&1}")
  end

  # --- Compose helpers ---

  # Picks an unused TCP port in the configured range. Bind-test only; the
  # actual reservation happens when Docker creates the port mapping.
  defp pick_free_host_port do
    case allocate_host_port(@host_port_range_start..@host_port_range_end, &port_listenable?/1) do
      {:ok, port} ->
        port

      :exhausted ->
        raise "No free host port in range #{@host_port_range_start}..#{@host_port_range_end}"
    end
  end

  defp port_listenable?(port) do
    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end

  # Pure port allocator: returns `{:ok, port}` for the first integer in
  # `range` that satisfies `free?`, or `:exhausted` when no element does
  # (including empty ranges). `free?` may be a function `(port -> bool)`
  # or a list of in-use ports — those are treated as taken. Exposed for
  # unit testing; production passes a TCP-bind probe.
  @doc false
  def allocate_host_port(range, in_use) when is_list(in_use) do
    set = MapSet.new(in_use)
    allocate_host_port(range, fn port -> not MapSet.member?(set, port) end)
  end

  def allocate_host_port(range, free?) when is_function(free?, 1) do
    case Enum.find(range, free?) do
      nil -> :exhausted
      port -> {:ok, port}
    end
  end

  # Classifies a Docker container row from `/containers/json` as
  # `:orphan` or `:active`. Used by `cleanup_orphans` and exposed for
  # tests so the rule (no job-scope label or an inactive job) stays explicit.
  @doc false
  def orphan_status(container, active_ids) when is_map(container) and is_list(active_ids) do
    job_scope_id = job_scope_id_from_container(container)

    if is_nil(job_scope_id) or job_scope_id not in active_ids do
      :orphan
    else
      :active
    end
  end

  @doc false
  def job_scope_id_from_container(container) when is_map(container) do
    labels =
      Map.get(container, "Labels") ||
        Map.get(container, :Labels) ||
        get_in(container, ["Config", "Labels"]) ||
        get_in(container, [:Config, :Labels]) ||
        %{}

    case Map.get(labels, "omashiki.job_scope_id") || Map.get(labels, :job_scope_id) do
      job_scope_id when is_binary(job_scope_id) and job_scope_id != "" -> job_scope_id
      _ -> nil
    end
  end

  def job_scope_id_from_container(_), do: nil

  @doc """
  Composes the Docker `HostConfig` block for an agent container.

  Mount strategy: the parent repo is bind-mounted **read-only** at the same
  absolute path so the worktree's `.git` pointer resolves; nested writable
  binds for `.git/` and the worktree directory grant the agent write access
  exactly where it needs it. Any other path under the repo root stays
  read-only inside the container.

  Hardening: drops every Linux capability, forbids privilege escalation,
  forces a read-only root filesystem (writable scratch via tmpfs), pins
  `Init: true` to reap zombies, and applies CPU/memory/PID limits.

  Network: port mapping binds to `127.0.0.1` only. OpenCode path adds
  `ExtraHosts` so `host.docker.internal` reaches the LLM gateway / Tools.Proxy
  on the host. Full private `NetworkMode` remains opt-in via
  `:agent_network_mode` (operator must still route gateway+proxy).
  """
  def build_host_config(repo_root, worktree_path, host_port, host_uid, host_gid, opts \\ [])
      when is_binary(repo_root) and is_binary(worktree_path) do
    limits = Keyword.get(opts, :resource_limits) || resource_limits()
    network_mode = Keyword.get(opts, :network_mode, agent_network_mode())
    git_dir = Path.join(repo_root, ".git")
    secret_host_path = Keyword.get(opts, :secret_host_path)
    secret_target = Keyword.get(opts, :secret_target)
    extra_binds = Keyword.get(opts, :extra_binds, [])
    internal_port = Keyword.get(opts, :internal_port)

    base_binds = [
      # Parent repo RO so the agent can read sibling code if needed.
      "#{repo_root}:#{repo_root}:ro",
      # Nested RW for git plumbing (objects, refs, worktrees/<group>/).
      "#{git_dir}:#{git_dir}",
      # Nested RW for the worktree itself; mounted at its absolute host
      # path so `.git` pointer files resolve.
      "#{worktree_path}:#{worktree_path}"
    ]

    binds =
      if is_binary(secret_host_path) and is_binary(secret_target) do
        # File bind mounts the host tmpfs file `:ro` straight into the
        # container's secret path. Docker creates the parent directory
        # on demand even with `ReadonlyRootfs: true` because file-target
        # binds are not treated as rootfs writes.
        base_binds ++ ["#{secret_host_path}:#{secret_target}:ro"] ++ extra_binds
      else
        base_binds ++ extra_binds
      end

    base = %{
      "Binds" => binds,
      # Sandbox.
      "CapDrop" => ["ALL"],
      "CapAdd" => [],
      "SecurityOpt" => ["no-new-privileges:true"],
      "ReadonlyRootfs" => true,
      "Tmpfs" => %{
        "/tmp" =>
          "rw,noexec,nosuid,size=#{Application.get_env(:omashiki, :agent_tmp_size_mb, 512)}m,uid=#{host_uid},gid=#{host_gid}"
      },
      "Init" => true,
      # Resource limits.
      "PidsLimit" => limits.pids_limit,
      "Memory" => limits.memory_bytes,
      "MemorySwap" => limits.memory_swap_bytes,
      "NanoCpus" => limits.nano_cpus
    }

    base =
      case network_mode do
        "host" ->
          base

        _ when is_integer(internal_port) and is_integer(host_port) ->
          Map.put(base, "PortBindings", %{
            "#{internal_port}/tcp" => [
              %{"HostIp" => "127.0.0.1", "HostPort" => Integer.to_string(host_port)}
            ]
          })

        _ ->
          base
      end

    base =
      if Keyword.get(opts, :gateway_host, false) and network_mode != "host" do
        # Linux Docker needs this alias so default gateway URL
        # `http://host.docker.internal:<port>/api/v1/gateway/v1` resolves.
        Map.put(base, "ExtraHosts", ["host.docker.internal:host-gateway"])
      else
        base
      end

    case network_mode do
      mode when is_binary(mode) and mode != "" -> Map.put(base, "NetworkMode", mode)
      _ -> base
    end
  end

  defp agent_network_mode, do: Application.get_env(:omashiki, :agent_network_mode)

  defp harness_endpoint(container_id, host_port, internal_port) do
    case agent_network_mode() do
      network when is_binary(network) and network not in ["", "host"] ->
        with {:ok, payload} <- docker_get("/containers/#{container_id}/json"),
             address when is_binary(address) and address != "" <-
               get_in(payload, ["NetworkSettings", "Networks", network, "IPAddress"]) do
          {:ok, {address, internal_port}}
        else
          {:error, reason} -> {:error, {:harness_endpoint_unavailable, reason}}
          _ -> {:error, :harness_endpoint_unavailable}
        end

      _ ->
        {:ok, {harness_host(), host_port}}
    end
  end

  defp resource_limits do
    Omashiki.HostSettings.get_limits()
  rescue
    _ ->
      case Application.get_env(:omashiki, :agent_resource_limits) do
        %{} = override -> Map.merge(@default_resource_limits, override)
        _ -> @default_resource_limits
      end
  end

  defp host_owner_ids(repo_root) do
    case File.stat(repo_root) do
      {:ok, %File.Stat{uid: uid, gid: gid}} -> {uid, gid}
      # Fallback to a sensible non-root default if stat fails (e.g. tests
      # against a fake path). Provisioning will later fail at the docker
      # call anyway, so this only matters for unit tests of the helper.
      _ -> {1000, 1000}
    end
  end

  defp harness_host do
    Application.get_env(:omashiki, :harness_host, "127.0.0.1")
  end

  # Splits a worktree path into its repository root and relative worktree path.
  @doc false
  def parent_repo_and_subpath(worktree_path) do
    abs = Path.expand(worktree_path)
    parent = abs |> Path.dirname() |> Path.dirname()
    sub = Path.relative_to(abs, parent)
    {parent, sub}
  end

  # ---------------------------------------------------------------------------
  # Docker HTTP plumbing
  # ---------------------------------------------------------------------------

  defp docker_ping do
    case mint_request("GET", "/_ping", [], nil) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp docker_get(path) do
    case mint_request("GET", path, [], nil) do
      {:ok, %{status: status, body: body}} when status in [200, 201] -> Jason.decode(body)
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{body: body}} -> {:error, Jason.decode!(body)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp docker_post(path, body) do
    json_body = Jason.encode!(body)
    headers = [{"content-type", "application/json"}]

    case mint_request("POST", path, headers, json_body) do
      {:ok, %{status: status, body: resp_body}} when status in [200, 201] ->
        {:ok, Jason.decode!(resp_body)}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{body: resp_body}} ->
        {:error, Jason.decode!(resp_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp docker_post_no_body(path) do
    headers = [{"content-type", "application/json"}]

    case mint_request("POST", path, headers, "") do
      {:ok, %{status: status}} when status in [200, 204, 304] -> :ok
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{body: resp_body}} -> {:error, Jason.decode!(resp_body)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp docker_delete(path) do
    case mint_request("DELETE", path, [], nil) do
      {:ok, %{status: status}} when status in [200, 204] -> :ok
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{body: resp_body}} -> {:error, Jason.decode!(resp_body)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Docker exec + attached start. Multiplexed stdout/stderr frames are
  # demuxed into a single string (stderr lines prefixed).
  defp do_exec_stream(container_id, cmd, opts) do
    env = Keyword.get(opts, :env, [])
    timeout_ms = Keyword.get(opts, :timeout_ms, 10 * 60 * 1_000)

    create_body = %{
      "AttachStdout" => true,
      "AttachStderr" => true,
      "AttachStdin" => false,
      "Tty" => false,
      "Cmd" => cmd
    }

    create_body = if env == [], do: create_body, else: Map.put(create_body, "Env", env)

    with {:ok, %{"Id" => exec_id}} <-
           docker_post("/containers/#{container_id}/exec", create_body),
         {:ok, stdout} <- docker_exec_start_stream(exec_id, timeout_ms) do
      exit_code =
        case docker_get("/exec/#{exec_id}/json") do
          {:ok, %{"ExitCode" => code}} when is_integer(code) -> code
          _ -> nil
        end

      {:ok, %{stdout: stdout, exit_code: exit_code}}
    end
  end

  defp docker_exec_start_stream(exec_id, timeout_ms) do
    body = Jason.encode!(%{"Detach" => false, "Tty" => false})
    headers = [{"content-type", "application/json"}]

    case mint_request("POST", "/exec/#{exec_id}/start", headers, body, timeout_ms) do
      {:ok, %{status: status, body: raw}} when status in 200..299 ->
        {_rest, stdout} = demux_docker_frames(raw, "")
        {:ok, stdout}

      {:ok, %{status: status, body: raw}} ->
        {:error, {:http_error, status, raw}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Docker multiplexed stream: 8-byte header + payload.
  # byte0 = stream (1 stdout, 2 stderr); bytes4..7 = size (uint32 BE).
  defp demux_docker_frames(buf, acc) when byte_size(buf) < 8, do: {buf, acc}

  defp demux_docker_frames(<<stream, _w1, _w2, _w3, size::32, rest::binary>> = buf, acc) do
    if byte_size(rest) < size do
      {buf, acc}
    else
      <<payload::binary-size(size), rest2::binary>> = rest

      chunk =
        case stream do
          1 -> payload
          2 -> "[stderr] " <> payload
          _ -> payload
        end

      demux_docker_frames(rest2, acc <> chunk)
    end
  end

  defp demux_docker_frames(buf, acc), do: {buf, acc}

  defp mint_request(method, path, headers, body, timeout_ms \\ 10_000) do
    full_path = "/#{@docker_api_version}#{path}"
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    case Mint.HTTP.connect(:http, {:local, @socket_path}, 0, hostname: "localhost") do
      {:ok, conn} ->
        case Mint.HTTP.request(conn, method, full_path, headers, body) do
          {:ok, conn, req_ref} ->
            receive_response(conn, req_ref, %{status: nil, body: ""}, deadline)

          {:error, conn, reason} ->
            Mint.HTTP.close(conn)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receive_response(conn, req_ref, acc, deadline) do
    timeout_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, responses} ->
            case process_responses(responses, req_ref, acc) do
              {:done, acc} ->
                Mint.HTTP.close(conn)
                {:ok, acc}

              {:error, reason} ->
                Mint.HTTP.close(conn)
                {:error, reason}

              {:cont, acc} ->
                receive_response(conn, req_ref, acc, deadline)
            end

          {:error, _conn, reason, _responses} ->
            {:error, reason}

          :unknown ->
            receive_response(conn, req_ref, acc, deadline)
        end
    after
      timeout_ms ->
        Mint.HTTP.close(conn)
        {:error, :timeout}
    end
  end

  defp process_responses([], _req_ref, acc), do: {:cont, acc}

  defp process_responses([response | rest], req_ref, acc) do
    case response do
      {:status, ^req_ref, status} ->
        process_responses(rest, req_ref, %{acc | status: status})

      {:headers, ^req_ref, _headers} ->
        process_responses(rest, req_ref, acc)

      {:data, ^req_ref, data} ->
        process_responses(rest, req_ref, %{acc | body: acc.body <> data})

      {:done, ^req_ref} ->
        {:done, acc}

      {:error, ^req_ref, reason} ->
        {:error, reason}

      _ ->
        process_responses(rest, req_ref, acc)
    end
  end
end
