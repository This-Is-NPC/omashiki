defmodule Omashiki.Jobs.Statuses do
  @moduledoc "Job lifecycle vocabulary shared by persistence, API, and admission."

  @all ~w(blocked queued provisioning running succeeded failed cancelled)
  @terminal ~w(succeeded failed cancelled)
  @active ~w(provisioning running)
  @retry_allowed ~w(failed cancelled)
  @max_payload_bytes 1_048_576

  defguard is_terminal(status) when status in @terminal
  defguard is_active(status) when status in @active
  defguard is_retry_allowed(status) when status in @retry_allowed

  def all, do: @all
  def terminal, do: @terminal
  def terminal?(status), do: status in @terminal
  def active, do: @active
  def active?(status), do: status in @active
  def retry_allowed, do: @retry_allowed
  def retry_allowed?(status), do: status in @retry_allowed
  def max_payload_bytes, do: @max_payload_bytes
end
