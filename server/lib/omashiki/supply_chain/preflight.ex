defmodule Omashiki.SupplyChain.Preflight.Violation do
  @moduledoc "A dependency rejected or reported by supply-chain preflight."

  defstruct [:dependency, :reason]
end

defmodule Omashiki.SupplyChain.Preflight.Report do
  @moduledoc "Deterministic result of inspecting one project root."

  defstruct root: nil,
            mode: nil,
            manifest: nil,
            checked: 0,
            violations: [],
            allowed?: false
end

defmodule Omashiki.SupplyChain.Preflight do
  @moduledoc """
  Pure policy evaluation over local manifests and lockfiles.

  `audit` returns a successful result with violations for rollout visibility;
  `allowlist` returns `{:error, report}` for any violation. Unknown source
  types, missing versions, missing hashes, and broken local paths are denied.
  """

  alias Omashiki.SupplyChain.{Manifest, Paths, Policy}
  alias Omashiki.SupplyChain.Preflight.{Report, Violation}
  require Logger

  @doc "Inspect manifests without applying a policy."
  def inspect(root), do: Manifest.inspect(root)

  @doc "Run a fail-closed preflight for one root and normalized policy."
  def run(root, policy, opts \\ [])

  def run(root, %Policy{} = policy, opts) do
    with {:ok, manifest} <- Manifest.inspect(root) do
      decisions =
        manifest.dependencies
        |> Enum.map(fn dependency ->
          {dependency, authorize_delivery(policy, dependency, opts)}
        end)

      violations =
        Enum.flat_map(decisions, fn
          {_dependency, {:allow, _reason}} -> []
          {dependency, {:deny, reason}} -> [%Violation{dependency: dependency, reason: reason}]
        end)

      emit_events(decisions, policy, opts)

      report = %Report{
        root: manifest.root,
        mode: policy.mode,
        manifest: manifest,
        checked: length(manifest.dependencies),
        violations: violations,
        allowed?: violations == [] or policy.mode in [:off, :audit]
      }

      if violations == [] or policy.mode in [:off, :audit],
        do: {:ok, report},
        else: {:error, report}
    end
  end

  def run(_, _, _), do: {:error, "preflight requires a normalized supply-chain policy"}

  defp authorize_delivery(%Policy{mode: :allowlist}, %{source: source}, _opts)
       when source in [:git, :direct_url] do
    {:deny,
     "remote #{source} sources are not mediated in allowlist mode; vendor the dependency under an allowlisted local root"}
  end

  defp authorize_delivery(policy, %{source: :local, path: path} = dependency, opts) do
    mounted_roots = Keyword.get(opts, :mounted_roots, [])

    case Policy.authorize(policy, dependency) do
      {:allow, _reason} when mounted_roots != [] ->
        if local_source_allowed?(path, mounted_roots),
          do: {:allow, "local source is allowlisted and mounted"},
          else: {:deny, "local source is allowlisted but is not mounted into the agent"}

      decision ->
        decision
    end
  end

  defp authorize_delivery(policy, dependency, _opts), do: Policy.authorize(policy, dependency)

  @doc "Check a local source with realpath containment and no symlink escape."
  def local_source_allowed?(path, roots) when is_binary(path) and is_list(roots) do
    with {:ok, path} <- Paths.real(path),
         true <- Enum.any?(roots, &contained_realpath?(path, &1)) do
      true
    else
      _ -> false
    end
  end

  def local_source_allowed?(_, _), do: false

  defp emit_events(decisions, policy, opts) do
    job_id = Keyword.get(opts, :job_id)
    cache_group = Keyword.get(opts, :cache_group)

    if is_binary(job_id) do
      Enum.each(decisions, fn {dependency, decision} ->
        {activity, outcome, reason} =
          case decision do
            {:allow, reason} ->
              {"registry.allowed", "ok", reason}

            {:deny, reason} ->
              {"registry.blocked", if(policy.mode == :audit, do: "ok", else: "denied"), reason}
          end

        Logger.debug("supply-chain preflight decision",
          job_id: job_id,
          activity: activity,
          outcome: outcome,
          ecosystem: dependency.ecosystem,
          package: dependency.name,
          version: dependency.version,
          source: to_string(dependency.source),
          cache_group: cache_group,
          policy_mode: policy.mode,
          forwarded: policy.mode == :audit,
          reason: reason
        )
      end)
    end
  end

  defp contained_realpath?(path, root) do
    with {:ok, root} <- Paths.real(root) do
      relative = Path.relative_to(path, root)

      relative == "." or
        (Path.type(relative) == :relative and relative != ".." and
           not String.starts_with?(relative, "../"))
    else
      _ -> false
    end
  end
end
