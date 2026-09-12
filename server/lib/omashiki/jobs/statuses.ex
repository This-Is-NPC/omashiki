defmodule Omashiki.Jobs.Statuses do
  @moduledoc "Job lifecycle vocabulary shared by persistence, API, and admission."

  @all ~w(blocked queued provisioning running succeeded failed cancelled)
  @terminal ~w(succeeded failed cancelled)
  @max_payload_bytes 1_048_576

  def all, do: @all
  def terminal, do: @terminal
  def terminal?(status), do: status in @terminal
  def retry_allowed?(status), do: status in ~w(failed cancelled)
  def max_payload_bytes, do: @max_payload_bytes
end
