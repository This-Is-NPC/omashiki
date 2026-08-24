defmodule Omashiki.Harness.Spec do
  @moduledoc "Immutable, configured harness profile resolved from the registry."

  @enforce_keys [:name, :adapter, :adapter_key, :options, :runtime, :launch_plan]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          adapter: module(),
          adapter_key: String.t(),
          options: map(),
          runtime: Omashiki.Runtimes.Runtime.t(),
          launch_plan: Omashiki.Harness.LaunchPlan.t()
        }
end

defmodule Omashiki.Harness.LaunchPlan do
  @moduledoc "Adapter-owned runtime launch and readiness metadata."

  @enforce_keys [:runtime, :transport, :startup, :readiness, :secret, :environment]
  defstruct @enforce_keys ++ [llm_egress: nil]

  @type t :: %__MODULE__{
          runtime: Omashiki.Runtimes.Runtime.t(),
          transport: map(),
          startup: map() | nil,
          readiness: map() | nil,
          secret: map() | nil,
          environment: [String.t()],
          llm_egress: atom() | nil
        }
end

defmodule Omashiki.Harness.Invocation do
  @moduledoc "Neutral instruction and JSON context passed to a harness adapter."

  @enforce_keys [:instruction, :context]
  defstruct @enforce_keys

  @type t :: %__MODULE__{instruction: String.t(), context: map() | nil}

  def new(%{"instruction" => instruction} = payload) when is_binary(instruction) do
    %__MODULE__{instruction: instruction, context: Map.get(payload, "context")}
  end
end

defmodule Omashiki.Harness.Result do
  @moduledoc "Neutral result returned by a harness adapter."

  defstruct assistant_text: "",
            input_tokens: nil,
            output_tokens: nil,
            cached_input_tokens: nil,
            cache_write_tokens: nil,
            model_resolved: nil,
            provider: nil,
            raw: nil

  @type t :: %__MODULE__{
          assistant_text: String.t(),
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cached_input_tokens: non_neg_integer() | nil,
          cache_write_tokens: non_neg_integer() | nil,
          model_resolved: String.t() | nil,
          provider: String.t() | nil,
          raw: map() | nil
        }

  def from_map(%__MODULE__{} = result), do: result
  def from_map(%{} = result), do: struct(__MODULE__, result)
end

defmodule Omashiki.Harness.Context do
  @moduledoc "Neutral adapter context with an injected runtime capability."

  defstruct job: nil,
            credential: nil,
            environment: %{},
            profile: nil,
            capability: nil,
            llm_egress: nil,
            runtime_mounts: %{},
            host_base_url: nil

  @type t :: %__MODULE__{
          job: map() | nil,
          credential: map() | nil,
          environment: map(),
          profile: Omashiki.Harness.Spec.t() | map() | nil,
          capability: Omashiki.Runtime.Capability.t() | nil,
          llm_egress: atom() | nil,
          runtime_mounts: map() | list(),
          host_base_url: String.t() | nil
        }
end
