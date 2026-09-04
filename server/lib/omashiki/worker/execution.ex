defmodule Omashiki.Worker.Execution do
  @moduledoc false

  @type t :: %__MODULE__{
          job_id: String.t(),
          attempt_id: String.t(),
          lease_token: String.t(),
          sink: String.t(),
          manager_id: String.t() | nil
        }

  defstruct [:job_id, :attempt_id, :lease_token, :sink, :manager_id]
end
