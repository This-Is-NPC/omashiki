defmodule Omashiki.Runtime.ContainerManager.Behaviour do
  @moduledoc "Contract for provisioning and controlling job runtime containers."

  @type provision_result :: %{
          required(:sandbox_id) => String.t(),
          optional(:host) => String.t(),
          optional(:port) => pos_integer(),
          required(:llm_egress) => :gateway | :engine,
          required(:transport) => map()
        }

  @callback provision_for_job(map(), map(), map(), keyword()) ::
              {:ok, provision_result()} | {:error, term()}

  @callback exec(String.t(), [String.t()], pos_integer()) ::
              {:ok, %{stdout: String.t(), exit_code: non_neg_integer() | nil}} | {:error, term()}

  @callback destroy(String.t()) :: :ok | {:error, term()}
  @callback cancel_scope(String.t()) :: :ok | {:error, term()}
  @callback cleanup_orphans() :: {:ok, [String.t()]} | {:error, term()}
  @callback fetch_logs(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
end

defmodule Omashiki.Runtime.ContainerManager.Operations do
  @moduledoc "Blocking container operations dispatched concurrently by ContainerManager."

  @callback op_provision(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback op_execute(String.t(), [String.t()], pos_integer()) :: {:ok, map()} | {:error, term()}
  @callback op_remove(String.t()) :: :ok | {:error, term()}
  @callback op_cancel_scope(String.t()) :: :ok | {:error, term()}
  @callback op_cleanup_orphans() :: {:ok, [String.t()]} | {:error, term()}
  @callback op_fetch_logs(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
end
