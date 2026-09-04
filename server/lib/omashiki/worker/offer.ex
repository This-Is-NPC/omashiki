defmodule Omashiki.Worker.Offer do
  @moduledoc """
  JSON-serialisable execution offer for a claimed attempt.
  """

  alias Omashiki.Jobs.{Job, JobAttempt}

  @type t :: %__MODULE__{
          job_id: String.t(),
          attempt_id: String.t(),
          lease_token: String.t(),
          sink: String.t(),
          payload: map() | nil,
          admitted_environment: map() | nil,
          admitted_repository: map() | nil,
          admitted_plugin: map() | nil,
          registry_digest: String.t() | nil,
          timeout_ms: pos_integer(),
          attempt_number: pos_integer(),
          user_id: String.t(),
          repository: String.t() | nil,
          environment: String.t(),
          admitted_environment_digest: String.t(),
          admitted_repository_digest: String.t() | nil,
          admitted_plugin_digest: String.t()
        }

  defstruct [
    :job_id,
    :attempt_id,
    :lease_token,
    :sink,
    :payload,
    :admitted_environment,
    :admitted_repository,
    :admitted_plugin,
    :registry_digest,
    :timeout_ms,
    :attempt_number,
    :user_id,
    :repository,
    :environment,
    :admitted_environment_digest,
    :admitted_repository_digest,
    :admitted_plugin_digest
  ]

  @doc "Build an offer from a claimed job and attempt."
  def from_claimed(%Job{} = job, %JobAttempt{} = attempt) do
    env = job.admitted_environment || %{}

    %__MODULE__{
      job_id: job.id,
      attempt_id: attempt.id,
      lease_token: attempt.lease_token,
      sink: Map.get(env, "sink"),
      payload: job.payload,
      admitted_environment: job.admitted_environment,
      admitted_repository: job.admitted_repository,
      admitted_plugin: job.admitted_plugin,
      registry_digest: job.registry_digest,
      timeout_ms: Map.get(env, "timeout_ms", 60_000),
      attempt_number: attempt.number,
      user_id: job.user_id,
      repository: job.repository,
      environment: job.environment,
      admitted_environment_digest: job.admitted_environment_digest,
      admitted_repository_digest: job.admitted_repository_digest,
      admitted_plugin_digest: job.admitted_plugin_digest
    }
  end

  @doc "Encode an offer for JSON transport."
  def to_map(%__MODULE__{} = offer) do
    %{
      "job_id" => offer.job_id,
      "attempt_id" => offer.attempt_id,
      "lease_token" => offer.lease_token,
      "sink" => offer.sink,
      "payload" => offer.payload,
      "admitted_environment" => offer.admitted_environment,
      "admitted_repository" => offer.admitted_repository,
      "admitted_plugin" => offer.admitted_plugin,
      "registry_digest" => offer.registry_digest,
      "timeout_ms" => offer.timeout_ms,
      "attempt_number" => offer.attempt_number,
      "user_id" => offer.user_id,
      "repository" => offer.repository,
      "environment" => offer.environment,
      "admitted_environment_digest" => offer.admitted_environment_digest,
      "admitted_repository_digest" => offer.admitted_repository_digest,
      "admitted_plugin_digest" => offer.admitted_plugin_digest
    }
  end

  @doc "Decode an offer from JSON transport."
  def from_map(map) when is_map(map) do
    {:ok,
     %__MODULE__{
       job_id: map["job_id"],
       attempt_id: map["attempt_id"],
       lease_token: map["lease_token"],
       sink: map["sink"],
       payload: Map.get(map, "payload"),
       admitted_environment: Map.get(map, "admitted_environment"),
       admitted_repository: Map.get(map, "admitted_repository"),
       admitted_plugin: Map.get(map, "admitted_plugin"),
       registry_digest: Map.get(map, "registry_digest"),
       timeout_ms: Map.get(map, "timeout_ms", 60_000),
       attempt_number: map["attempt_number"],
       user_id: map["user_id"],
       repository: Map.get(map, "repository"),
       environment: map["environment"],
       admitted_environment_digest: map["admitted_environment_digest"],
       admitted_repository_digest: Map.get(map, "admitted_repository_digest"),
       admitted_plugin_digest: map["admitted_plugin_digest"]
     }}
  end
end
