defmodule Omashiki.Application do
  @moduledoc false

  use Application

  require Logger

  @type boot_role :: :embedded | :manager | :worker

  @spec boot_role() :: boot_role()
  def boot_role do
    normalize_boot_role(Application.get_env(:omashiki, :boot_role, :embedded))
  end

  @spec children_for(boot_role() | String.t()) :: [Supervisor.child_spec() | module()]
  def children_for(role) do
    case normalize_boot_role(role) do
      :embedded -> embedded_children()
      :manager -> manager_children()
      :worker -> worker_children()
    end
  end

  @impl true
  def start(_type, _args) do
    role = boot_role()
    install_logger_filter()
    OmashikiWeb.RateLimiter.ensure_table()
    Omashiki.Runtime.ContainerManager.ensure_cancellation_table()

    unless role == :worker do
      OmashikiWeb.AuthMode.assert_boot_safe!()
    end

    load_declared_config(role)

    if role == :worker do
      Omashiki.Worker.State.restore!()
    end

    children = children_for(role)



    opts = [strategy: :one_for_one, name: Omashiki.Supervisor]
    {:ok, sup_pid} = Supervisor.start_link(children, opts)

    post_start(role)

    {:ok, sup_pid}
  end

  defp embedded_children do
    [
      Omashiki.Telemetry,
      Omashiki.Repo,
      {Phoenix.PubSub, name: Omashiki.PubSub},
      {Registry, keys: :unique, name: Omashiki.Runtime.AttemptRegistry},
      {Task.Supervisor, name: Omashiki.Runtime.TaskSupervisor},
      {Task.Supervisor,
       name: Omashiki.ApiTokens.TaskSupervisor,
       max_children: Application.get_env(:omashiki, :api_token_use_max_children, 512)},
      Omashiki.Runtime.AttemptSupervisor,
      Omashiki.Runtime.PortAllocator,
      Omashiki.Runtime.LeaseRenewer,
      Omashiki.Runtime.ContainerManager,
      Omashiki.Runtime.Inspector,
      Omashiki.Config.Rollout,
      Omashiki.Runtimes.CacheMaintenance,
      {Oban, Application.fetch_env!(:omashiki, Oban)},
      Omashiki.Gateway.CircuitBreaker,
      OmashikiWeb.Endpoint,
      Omashiki.SupplyChain.SocketBridge
    ] ++ recovery_children()
  end

  defp manager_children do
    [
      Omashiki.Telemetry,
      Omashiki.Repo,
      {Phoenix.PubSub, name: Omashiki.PubSub},
      {Task.Supervisor,
       name: Omashiki.ApiTokens.TaskSupervisor,
       max_children: Application.get_env(:omashiki, :api_token_use_max_children, 512)},
      Omashiki.Config.Rollout,
      Omashiki.Runtimes.CacheMaintenance,
      manager_oban_child(),
      Omashiki.Gateway.CircuitBreaker,
      OmashikiWeb.Endpoint,
      Omashiki.SupplyChain.SocketBridge
    ] ++ recovery_children()
  end

  defp worker_children do
    [
      Omashiki.Telemetry,
      {Phoenix.PubSub, name: Omashiki.PubSub},
      {Registry, keys: :unique, name: Omashiki.Runtime.AttemptRegistry},
      {Task.Supervisor, name: Omashiki.Runtime.TaskSupervisor},
      Omashiki.Runtime.AttemptSupervisor,
      Omashiki.Runtime.PortAllocator,
      Omashiki.Runtimes.CacheMaintenance,
      Omashiki.Runtime.ContainerManager,
      Omashiki.Runtime.Inspector,
      Omashiki.LlmEgress.Proxy,
      Omashiki.Worker.Enroll.Listener,
      Omashiki.Worker.Slots,
      Omashiki.Worker.Poller
    ]
  end

  defp manager_oban_child do
    oban_config = Application.fetch_env!(:omashiki, Oban)
    {Oban, Keyword.put(oban_config, :queues, webhooks: 5)}
  end

  defp recovery_children do
    if Application.get_env(:omashiki, :enable_job_recovery, true),
      do: [Omashiki.Jobs.Recovery],
      else: []
  end

  defp normalize_boot_role(role) when role in [:embedded, :manager, :worker], do: role
  defp normalize_boot_role("embedded"), do: :embedded
  defp normalize_boot_role("manager"), do: :manager
  defp normalize_boot_role("worker"), do: :worker

  defp normalize_boot_role(other),
    do: raise(ArgumentError, "invalid boot_role: #{inspect(other)}")

  defp post_start(:embedded) do
    sync_execution_capacity()
    run_orphan_cleanup()
  end

  defp post_start(:manager) do
    sync_execution_capacity()
  end

  defp post_start(:worker) do
    if Application.get_env(:omashiki, :run_orphan_cleanup_on_boot, true) do
      _ = Omashiki.Runtime.ContainerManager.cleanup_orphans()
    end

    :ok
  rescue
    e -> Logger.warning("[Application] Worker orphan cleanup skipped: #{inspect(e)}")
  end

  # `[limits].max_concurrent_containers` owns the database capacity row.
  defp sync_execution_capacity do
    if Application.get_env(:omashiki, :sync_execution_capacity_on_boot, true) do
      _ = Omashiki.Jobs.sync_capacity()
    end

    :ok
  rescue
    e -> Logger.warning("[Application] Execution capacity sync skipped: #{inspect(e)}")
  end

  defp load_declared_config(:worker) do
    Omashiki.Config.reset!()
    Omashiki.Worker.State.restore!()
    :ok
  rescue
    e ->
      Logger.error("[Application] config reset failed: #{inspect(e)}")
      reraise e, __STACKTRACE__
  end

  defp load_declared_config(_role) do
    if Application.get_env(:omashiki, :skip_toml_config, false) do
      Omashiki.Config.reset!()
    else
      Omashiki.Config.load!()
    end

    :ok
  rescue
    e ->
      Logger.error("[Application] omashiki.toml config failed: #{inspect(e)}")
      reraise e, __STACKTRACE__
  end

  defp install_logger_filter do
    _ =
      :logger.add_primary_filter(
        :omashiki_token_scrub,
        {&OmashikiWeb.LoggerFilter.filter/2, []}
      )

    :ok
  rescue
    _ -> :ok
  end

  @impl true
  def config_change(changed, _new, removed) do
    if boot_role() != :worker do
      OmashikiWeb.Endpoint.config_change(changed, removed)
    end

    :ok
  end

  defp run_orphan_cleanup do
    if Application.get_env(:omashiki, :run_orphan_cleanup_on_boot, true) do
      _ = Omashiki.Runtime.ContainerManager.cleanup_orphans()
      _ = Omashiki.Runtimes.CacheMaintenance.run()
      _ = Omashiki.Jobs.GitArtifact.prune_worktrees()
    end

    :ok
  rescue
    e -> Logger.warning("[Application] Orphan cleanup skipped: #{inspect(e)}")
  end
end
