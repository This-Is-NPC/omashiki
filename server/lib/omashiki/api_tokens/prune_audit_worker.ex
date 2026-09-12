defmodule Omashiki.ApiTokens.PruneAuditWorker do
  @moduledoc "Drop token audit rows older than `[auth] token_audit_retention_days`."

  use Oban.Worker, queue: :token_audit, max_attempts: 3

  alias Omashiki.ApiTokens.Audit

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    days = Application.get_env(:omashiki, :token_audit_retention_days, 90)
    cutoff = DateTime.add(DateTime.utc_now(:microsecond), -days, :day)
    Audit.prune(cutoff)
  end
end
