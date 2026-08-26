defmodule Omashiki.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    install_logger_filter()
    OmashikiWeb.RateLimiter.ensure_table()
    OmashikiWeb.AuthMode.assert_boot_safe!()

    recovery_children =
      if Application.get_env(:omashiki, :enable_job_recovery, true),
        do: [Omashiki.Jobs.Recovery],
        else: []

    children =
      [
        # First: it attaches the handlers for `Omashiki.Telemetry.events/0`, and
        # a handler that starts after the first emitter has already missed the
        # events it exists to observe.
        Omashiki.Telemetry,
        Omashiki.Repo,
        {Phoenix.PubSub, name: Omashiki.PubSub},
        {Registry, keys: :unique, name: Omashiki.Runtime.AttemptRegistry},
        {Task.Supervisor, name: Omashiki.Runtime.TaskSupervisor},
        # Fire-and-forget `last_used_at` writes for api tokens. Separate from the
        # runtime supervisor so an auth-path burst cannot starve container work,
        # and bounded so an overload sheds those writes — they carry 60s of
        # resolution, so dropping one is cheaper than spawning without limit.
        {Task.Supervisor,
         name: Omashiki.ApiTokens.TaskSupervisor,
         max_children: Application.get_env(:omashiki, :api_token_use_max_children, 512)},
        Omashiki.Runtime.AttemptSupervisor,
        Omashiki.Runtime.PortAllocator,
        Omashiki.Runtime.LeaseRenewer,
        Omashiki.Runtime.ContainerManager,
        Omashiki.Runtime.Inspector,
        Omashiki.Runtimes.CacheMaintenance,
        {Oban, Application.fetch_env!(:omashiki, Oban)},
        Omashiki.Gateway.CircuitBreaker,
        OmashikiWeb.Endpoint,
        Omashiki.LlmEgress.Proxy,
        Omashiki.SupplyChain.SocketBridge
      ] ++ recovery_children

    opts = [strategy: :one_for_one, name: Omashiki.Supervisor]
    {:ok, sup_pid} = Supervisor.start_link(children, opts)

    load_declared_config()
    sync_execution_capacity()
    run_orphan_cleanup()

    {:ok, sup_pid}
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

  # Declarative config from omashiki.toml. Tests skip the developer file.
  defp load_declared_config do
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
    OmashikiWeb.Endpoint.config_change(changed, removed)
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
