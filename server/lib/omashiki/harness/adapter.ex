defmodule Omashiki.Harness.Adapter do
  @moduledoc "Single contract implemented by every configured plugin."

  alias Omashiki.Harness.{Context, Invocation, LaunchPlan, Result}
  alias Omashiki.Plugin.{Manifest, Preset}

  @callback validate_options(Manifest.t(), map()) :: :ok | {:error, term()}
  @callback launch_plan(Preset.t()) :: {:ok, LaunchPlan.t()} | {:error, term()}
  @callback prepare(Preset.t(), Context.t()) :: {:ok, LaunchPlan.t()} | {:error, term()}
  @callback invoke(Invocation.t(), Context.t()) :: {:ok, Result.t()} | {:error, term()}
end
