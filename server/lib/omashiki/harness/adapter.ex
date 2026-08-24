defmodule Omashiki.Harness.Adapter do
  @moduledoc "Single contract implemented by every configured harness adapter."

  alias Omashiki.Harness.{Context, Invocation, LaunchPlan, Result, Spec}

  @callback validate_options(map()) :: :ok | {:error, term()}
  @callback launch_plan(Spec.t()) :: {:ok, LaunchPlan.t()} | {:error, term()}
  @callback prepare(Spec.t(), Context.t()) :: {:ok, LaunchPlan.t()} | {:error, term()}
  @callback invoke(Invocation.t(), Context.t()) :: {:ok, Result.t()} | {:error, term()}
end
