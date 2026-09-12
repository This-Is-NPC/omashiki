defmodule Omashiki.Jobs.Statuses do
  @moduledoc "Job lifecycle vocabulary shared by persistence, API, and admission."

  @all ~w(blocked queued provisioning running succeeded failed cancelled)
  @terminal ~w(succeeded failed cancelled)
  @active ~w(provisioning running)
  @unsuccessful ~w(failed cancelled)
  @max_payload_bytes 1_048_576

  defguard is_terminal(status) when status in @terminal
  defguard is_active(status) when status in @active
  defguard is_unsuccessful(status) when status in @unsuccessful

  def all, do: @all
  def terminal, do: @terminal
  def terminal?(status) when is_terminal(status), do: true
  def terminal?(_), do: false
  def active, do: @active
  def active?(status) when is_active(status), do: true
  def active?(_), do: false
  def max_payload_bytes, do: @max_payload_bytes
end
