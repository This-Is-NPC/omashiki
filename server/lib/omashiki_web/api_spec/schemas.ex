defmodule OmashikiWeb.ApiSpec.Schemas do
  @moduledoc "OpenAPI schemas. This is the request and response contract."
end

defmodule OmashikiWeb.ApiSpec.Schemas.Problem do
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Problem",
    description: "RFC 9457 problem details for every API error.",
    type: :object,
    additionalProperties: false,
    required: [:type, :title, :status, :code, :detail, :errors, :request_id],
    properties: %{
      type: %OpenApiSpex.Schema{type: :string, example: "about:blank"},
      title: %OpenApiSpex.Schema{type: :string},
      status: %OpenApiSpex.Schema{type: :integer},
      code: %OpenApiSpex.Schema{type: :string, enum: OmashikiWeb.Api.Problem.codes()},
      detail: %OpenApiSpex.Schema{type: :string},
      errors: %OpenApiSpex.Schema{
        type: :array,
        items: %OpenApiSpex.Schema{
          type: :object,
          additionalProperties: true,
          properties: %{
            field: %OpenApiSpex.Schema{type: :string},
            code: %OpenApiSpex.Schema{type: :string}
          }
        }
      },
      request_id: %OpenApiSpex.Schema{type: :string, nullable: true}
    }
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.JobPayload do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "JobPayload",
    type: :object,
    additionalProperties: false,
    required: [:instruction],
    properties: %{
      instruction: %Schema{type: :string, minLength: 1, maxLength: 1_048_576},
      context: %Schema{type: :object, additionalProperties: true},
      branch: %Schema{type: :string, minLength: 1, maxLength: 255},
      title: %Schema{type: :string, minLength: 1, maxLength: 255}
    }
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.JobDependency do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "JobDependency",
    type: :object,
    additionalProperties: false,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      ref: %Schema{type: :string, minLength: 1, maxLength: 128},
      on_failure: %Schema{type: :string, enum: ["cancel", "block", "proceed"]}
    }
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.JobAdmissionRequest do
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias OmashikiWeb.ApiSpec.Schemas.{JobDependency, JobPayload}

  OpenApiSpex.schema(%{
    title: "JobAdmissionRequest",
    type: :object,
    additionalProperties: false,
    required: [:idempotency_key, :correlation_id, :environment, :payload, :priority],
    properties: %{
      idempotency_key: %Schema{type: :string, minLength: 1, maxLength: 255},
      correlation_id: %Schema{type: :string, minLength: 1, maxLength: 255},
      repo: %Schema{type: :string, minLength: 1, maxLength: 255},
      environment: %Schema{type: :string, minLength: 1, maxLength: 255},
      payload: JobPayload,
      priority: %Schema{type: :integer, minimum: 0, maximum: 3},
      depends_on: %Schema{type: :array, items: JobDependency},
      base: %Schema{type: :string, minLength: 1, maxLength: 255}
    }
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.JobBatchItem do
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias OmashikiWeb.ApiSpec.Schemas.{JobDependency, JobPayload}

  OpenApiSpex.schema(%{
    title: "JobBatchItem",
    type: :object,
    additionalProperties: false,
    required: [:ref, :idempotency_key, :environment, :payload, :priority],
    properties: %{
      ref: %Schema{type: :string, minLength: 1, maxLength: 128},
      idempotency_key: %Schema{type: :string, minLength: 1, maxLength: 255},
      repo: %Schema{type: :string, minLength: 1, maxLength: 255},
      environment: %Schema{type: :string, minLength: 1, maxLength: 255},
      payload: JobPayload,
      priority: %Schema{type: :integer, minimum: 0, maximum: 3},
      depends_on: %Schema{type: :array, items: JobDependency},
      base: %Schema{type: :string, minLength: 1, maxLength: 255}
    }
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.JobBatchRequest do
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias OmashikiWeb.ApiSpec.Schemas.JobBatchItem

  OpenApiSpex.schema(%{
    title: "JobBatchRequest",
    type: :object,
    additionalProperties: false,
    required: [:correlation_id, :jobs],
    properties: %{
      correlation_id: %Schema{type: :string, minLength: 1, maxLength: 255},
      jobs: %Schema{type: :array, minItems: 1, items: JobBatchItem}
    }
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.Job do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Job",
    type: :object,
    additionalProperties: false,
    required: [
      :id,
      :idempotency_key,
      :correlation_id,
      :environment,
      :payload,
      :priority,
      :status,
      :attempt,
      :depends_on,
      :submitted_at
    ],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      idempotency_key: %Schema{type: :string},
      correlation_id: %Schema{type: :string},
      repo: %Schema{type: :string, nullable: true},
      environment: %Schema{type: :string},
      payload: %Schema{type: :object},
      priority: %Schema{type: :integer},
      status: %Schema{
        type: :string,
        enum: Omashiki.Jobs.Statuses.all()
      },
      attempt: %Schema{type: :integer},
      depends_on: %Schema{type: :array, items: %Schema{type: :string, format: :uuid}},
      submitted_at: %Schema{type: :string, format: :"date-time"},
      queued_at: %Schema{type: :string, format: :"date-time", nullable: true},
      started_at: %Schema{type: :string, format: :"date-time", nullable: true},
      finished_at: %Schema{type: :string, format: :"date-time", nullable: true}
    }
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.JobResponse do
  require OpenApiSpex
  alias OmashikiWeb.ApiSpec.Schemas.Job

  OpenApiSpex.schema(%{
    title: "JobResponse",
    type: :object,
    additionalProperties: false,
    required: [:data],
    properties: %{data: Job}
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.JobListResponse do
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias OmashikiWeb.ApiSpec.Schemas.Job

  OpenApiSpex.schema(%{
    title: "JobListResponse",
    type: :object,
    additionalProperties: false,
    required: [:data, :next_cursor],
    properties: %{
      data: %Schema{type: :array, items: Job},
      next_cursor: %Schema{type: :string, nullable: true}
    }
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.FileChange do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "FileChange",
    type: :object,
    additionalProperties: false,
    properties: %{
      path: %Schema{type: :string},
      insertions: %Schema{type: :integer},
      deletions: %Schema{type: :integer}
    }
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.JobChanges do
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias OmashikiWeb.ApiSpec.Schemas.FileChange

  OpenApiSpex.schema(%{
    title: "JobChanges",
    type: :object,
    additionalProperties: false,
    properties: %{
      files_changed: %Schema{type: :integer},
      insertions: %Schema{type: :integer},
      deletions: %Schema{type: :integer},
      files: %Schema{type: :array, items: FileChange}
    }
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.JobResult do
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias OmashikiWeb.ApiSpec.Schemas.JobChanges

  OpenApiSpex.schema(%{
    title: "JobResult",
    type: :object,
    additionalProperties: false,
    required: [:job_id, :attempt, :status],
    properties: %{
      job_id: %Schema{type: :string, format: :uuid},
      attempt: %Schema{type: :integer},
      status: %Schema{type: :string, enum: Omashiki.Jobs.Statuses.terminal()},
      branch: %Schema{type: :string, nullable: true},
      base_sha: %Schema{type: :string, nullable: true},
      head_sha: %Schema{type: :string, nullable: true},
      worktree_clean: %Schema{type: :boolean, nullable: true},
      summary: %Schema{type: :string, nullable: true},
      changes: JobChanges,
      compare_url: %Schema{type: :string, nullable: true},
      result: %Schema{type: :object, nullable: true},
      error: %Schema{type: :object, nullable: true},
      finished_at: %Schema{type: :string, format: :"date-time", nullable: true}
    }
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.JobResultResponse do
  require OpenApiSpex
  alias OmashikiWeb.ApiSpec.Schemas.JobResult

  OpenApiSpex.schema(%{
    title: "JobResultResponse",
    type: :object,
    additionalProperties: false,
    required: [:data],
    properties: %{data: JobResult}
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.JobEvent do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "JobEvent",
    type: :object,
    additionalProperties: false,
    required: [:event_id, :job_id, :attempt, :sequence, :type, :status],
    properties: %{
      event_id: %Schema{type: :string, format: :uuid},
      job_id: %Schema{type: :string, format: :uuid},
      attempt: %Schema{type: :integer},
      sequence: %Schema{type: :integer},
      type: %Schema{type: :string},
      status: %Schema{type: :string},
      step: %Schema{type: :string},
      outcome: %Schema{type: :string},
      correlation_id: %Schema{type: :string},
      occurred_at: %Schema{type: :string, format: :"date-time"},
      recorded_at: %Schema{type: :string, format: :"date-time"},
      data: %Schema{type: :object}
    }
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.JobEventListResponse do
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias OmashikiWeb.ApiSpec.Schemas.JobEvent

  OpenApiSpex.schema(%{
    title: "JobEventListResponse",
    type: :object,
    additionalProperties: false,
    required: [:data],
    properties: %{data: %Schema{type: :array, items: JobEvent}}
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.Repository do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Repository",
    type: :object,
    additionalProperties: false,
    required: [:name, :base_branch],
    properties: %{
      name: %Schema{type: :string},
      base_branch: %Schema{type: :string}
    }
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.RepositoryListResponse do
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias OmashikiWeb.ApiSpec.Schemas.Repository

  OpenApiSpex.schema(%{
    title: "RepositoryListResponse",
    type: :object,
    additionalProperties: false,
    required: [:data],
    properties: %{data: %Schema{type: :array, items: Repository}}
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.Environment do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Environment",
    type: :object,
    additionalProperties: false,
    required: [:name],
    properties: %{
      name: %Schema{type: :string},
      preset: %Schema{type: :string},
      plugin: %Schema{type: :string},
      runtime: %Schema{type: :string},
      handler: %Schema{type: :string},
      backend: %Schema{type: :string},
      distribution: %Schema{type: :string},
      image: %Schema{type: :string},
      timeout_ms: %Schema{type: :integer},
      network: %Schema{type: :string},
      capabilities: %Schema{type: :array, items: %Schema{type: :string}},
      resources: %Schema{type: :object}
    }
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.EnvironmentListResponse do
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias OmashikiWeb.ApiSpec.Schemas.Environment

  OpenApiSpex.schema(%{
    title: "EnvironmentListResponse",
    type: :object,
    additionalProperties: false,
    required: [:data],
    properties: %{data: %Schema{type: :array, items: Environment}}
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.FleetContainer do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "FleetContainer",
    type: :object,
    additionalProperties: false,
    properties: %{
      id: %Schema{type: :string},
      state: %Schema{type: :string},
      created_at: %Schema{type: :string, nullable: true},
      started_at: %Schema{type: :string, nullable: true},
      job_id: %Schema{type: :string, format: :uuid, nullable: true}
    }
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.FleetNode do
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias OmashikiWeb.ApiSpec.Schemas.FleetContainer

  OpenApiSpex.schema(%{
    title: "FleetNode",
    type: :object,
    additionalProperties: false,
    properties: %{
      machine_id: %Schema{type: :string},
      kind: %Schema{type: :string},
      stale: %Schema{type: :boolean},
      last_seen_at: %Schema{type: :string, nullable: true},
      capacity: %Schema{type: :integer, nullable: true},
      free_slots: %Schema{type: :integer, nullable: true},
      containers: %Schema{type: :array, items: FleetContainer}
    }
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.FleetResponse do
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias OmashikiWeb.ApiSpec.Schemas.FleetNode

  OpenApiSpex.schema(%{
    title: "FleetResponse",
    type: :object,
    additionalProperties: false,
    required: [:data],
    properties: %{data: %Schema{type: :array, items: FleetNode}}
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.Health do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Health",
    type: :object,
    additionalProperties: false,
    required: [:status],
    properties: %{status: %Schema{type: :string, example: "ok"}}
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.IssueTokenRequest do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "IssueTokenRequest",
    type: :object,
    additionalProperties: false,
    required: [:username, :password, :scopes, :allowed_environments, :max_active_jobs, :ttl_days],
    properties: %{
      username: %Schema{type: :string, minLength: 1},
      password: %Schema{type: :string, minLength: 1},
      name: %Schema{type: :string, maxLength: 80},
      scopes: %Schema{
        type: :array,
        minItems: 1,
        items: %Schema{type: :string, enum: ["read", "submit", "cancel"]}
      },
      allowed_environments: %Schema{type: :array, minItems: 1, items: %Schema{type: :string}},
      max_active_jobs: %Schema{type: :integer, minimum: 1},
      ttl_days: %Schema{type: :integer, minimum: 1, maximum: 365}
    }
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.SignupRequest do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "SignupRequest",
    type: :object,
    additionalProperties: false,
    required: [
      :email,
      :username,
      :password,
      :scopes,
      :allowed_environments,
      :max_active_jobs,
      :ttl_days
    ],
    properties: %{
      email: %Schema{type: :string, format: :email},
      username: %Schema{type: :string, minLength: 1},
      password: %Schema{type: :string, minLength: 1},
      name: %Schema{type: :string, maxLength: 80},
      scopes: %Schema{
        type: :array,
        minItems: 1,
        items: %Schema{type: :string, enum: ["read", "submit", "cancel"]}
      },
      allowed_environments: %Schema{type: :array, minItems: 1, items: %Schema{type: :string}},
      max_active_jobs: %Schema{type: :integer, minimum: 1},
      ttl_days: %Schema{type: :integer, minimum: 1, maximum: 365}
    }
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.TokenData do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "TokenData",
    type: :object,
    additionalProperties: false,
    required: [:token, :name, :expires_at, :scopes],
    properties: %{
      token: %Schema{type: :string},
      name: %Schema{type: :string},
      expires_at: %Schema{type: :string, format: :"date-time"},
      scopes: %Schema{type: :array, items: %Schema{type: :string}},
      allowed_environments: %Schema{type: :array, items: %Schema{type: :string}},
      max_active_jobs: %Schema{type: :integer}
    }
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.TokenResponse do
  require OpenApiSpex
  alias OmashikiWeb.ApiSpec.Schemas.TokenData

  OpenApiSpex.schema(%{
    title: "TokenResponse",
    type: :object,
    additionalProperties: false,
    required: [:data],
    properties: %{data: TokenData}
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.SignupUser do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "SignupUser",
    type: :object,
    additionalProperties: false,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      email: %Schema{type: :string},
      username: %Schema{type: :string}
    }
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.SignupResponse do
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias OmashikiWeb.ApiSpec.Schemas.SignupUser

  OpenApiSpex.schema(%{
    title: "SignupResponse",
    type: :object,
    additionalProperties: false,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        additionalProperties: false,
        required: [:token, :user],
        properties: %{
          token: %Schema{type: :string},
          user: SignupUser
        }
      }
    }
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.WebhookDelivery do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "WebhookDelivery",
    type: :object,
    additionalProperties: false,
    required: [:id, :status],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      event_id: %Schema{type: :string, format: :uuid},
      destination: %Schema{type: :string},
      status: %Schema{type: :string, enum: ["pending", "delivering", "delivered", "failed", "dead"]},
      attempts: %Schema{type: :integer},
      next_attempt_at: %Schema{type: :string, format: :"date-time", nullable: true},
      delivered_at: %Schema{type: :string, format: :"date-time", nullable: true},
      last_response_status: %Schema{type: :integer, nullable: true},
      last_error: %Schema{type: :object, nullable: true},
      inserted_at: %Schema{type: :string, format: :"date-time"},
      updated_at: %Schema{type: :string, format: :"date-time"}
    }
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.WebhookDeliveryListResponse do
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias OmashikiWeb.ApiSpec.Schemas.WebhookDelivery

  OpenApiSpex.schema(%{
    title: "WebhookDeliveryListResponse",
    type: :object,
    additionalProperties: false,
    required: [:data],
    properties: %{data: %Schema{type: :array, items: WebhookDelivery}}
  })
end

defmodule OmashikiWeb.ApiSpec.Schemas.OpenApiDocument do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "OpenApiDocument",
    type: :object,
    additionalProperties: true,
    required: [:openapi, :info, :paths],
    properties: %{
      openapi: %Schema{type: :string},
      info: %Schema{type: :object},
      paths: %Schema{type: :object}
    }
  })
end
