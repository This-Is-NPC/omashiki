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
        Omashiki.Repo,
        {Phoenix.PubSub, name: Omashiki.PubSub},
        {Task.Supervisor, name: Omashiki.Runtime.TaskSupervisor},
        Omashiki.Runtime.PortAllocator,
        Omashiki.Runtime.LeaseRenewer,
        Omashiki.Runtime.ContainerManager,
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
    run_orphan_cleanup()

    {:ok, sup_pid}
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
    end

    :ok
  rescue
    e -> Logger.warning("[Application] Orphan cleanup skipped: #{inspect(e)}")
  end
end
