defmodule Omashiki.ArchitectureTest do
  @moduledoc """
  Reflection half of the architecture gate (`.scripts/arch_check.sh`).

  Eleven of the thirteen invariants are statically checkable and live in that
  script as greps. The two here are not: they need the compiled application to
  answer questions no grep can answer.

  * **INV5 — port contracts carry no vendor vocabulary.** A grep can only look
    at the files someone remembered to list, and only at whole files. This
    enumerates *every* behaviour compiled into `:omashiki` (so a port added
    tomorrow is covered by construction) and reads only the callback and type
    specs — not moduledocs, not function bodies. That distinction is
    load-bearing: `Omashiki.Gateway.Provider` is the vendor seam and names
    Anthropic and OpenAI in its moduledoc on purpose, while its contract stays
    neutral. Source text cannot tell those two apart; a typespec can.

  * **INV7 — orphan behaviour.** Reclaiming abandoned containers is a property
    of the runtime port and of boot, not of one function. This pins the
    callback onto the port, pins the classification rule (no job-scope label,
    or a job-scope id that is not active), and pins the boot wiring by reading
    the application module's external-call table.
  """

  use ExUnit.Case, async: true

  alias Omashiki.Runtime.ContainerManager

  # Vendor and product names. A port contract that needs one of these has
  # stopped being a port: it has become an interface to one supplier.
  @vendor_words ~w(
    docker podman containerd
    opencode claudecode claude_code codex
    anthropic openai ollama gemini bedrock vertex
  )

  # The ports we know about today. Discovery is what actually drives INV5 —
  # this list exists so a discovery bug cannot make the check vacuously green.
  @known_contracts [
    Omashiki.Gateway.Provider,
    Omashiki.Harness.Adapter,
    Omashiki.Jobs.Runner.Container,
    Omashiki.Runtime.ContainerManager.Behaviour
  ]

  describe "INV5  port contracts use no vendor vocabulary" do
    test "the application declares the port contracts we think it declares" do
      discovered = port_contracts()

      assert discovered != [],
             "no behaviours found in :omashiki — INV5 would pass vacuously. " <>
               "Is the application compiled and loaded?"

      missing = @known_contracts -- discovered

      assert missing == [],
             "expected port contracts were not discovered by reflection: " <>
               "#{inspect(missing)}. Either they were renamed/removed (update " <>
               "@known_contracts and say why in the commit) or discovery is broken."
    end

    test "no callback or type in any port contract names a vendor" do
      violations =
        for module <- port_contracts(),
            {label, text} <- contract_surface(module),
            word <- @vendor_words,
            String.contains?(String.downcase(text), word) do
          "#{inspect(module)} #{label}: #{String.trim(text)} (matched #{inspect(word)})"
        end

      assert violations == [],
             "port contracts must not name a vendor:\n  " <> Enum.join(violations, "\n  ")
    end

    test "the vendor detector actually detects" do
      # Guards the check against rotting into a no-op: if the scanner ever
      # stops matching, this fails before the real assertion goes quiet.
      assert vendor_hits("@callback provision(docker_id :: String.t()) :: :ok") == ["docker"]
      assert vendor_hits("@callback invoke(Anthropic.Request.t()) :: :ok") == ["anthropic"]
      assert vendor_hits("@callback provision(sandbox_id :: String.t()) :: :ok") == []
    end
  end

  describe "INV7  orphan reclamation is a property of the runtime port" do
    test "the port declares cleanup_orphans/0 and the adapter implements it" do
      callbacks = ContainerManager.Behaviour.behaviour_info(:callbacks)

      assert {:cleanup_orphans, 0} in callbacks,
             "the runtime port must declare cleanup_orphans/0; found #{inspect(callbacks)}"

      Code.ensure_loaded!(ContainerManager)

      unimplemented =
        Enum.reject(callbacks, fn {name, arity} ->
          function_exported?(ContainerManager, name, arity)
        end)

      assert unimplemented == [],
             "ContainerManager does not implement #{inspect(unimplemented)}"
    end

    test "a container with no job-scope label is an orphan" do
      assert ContainerManager.orphan_status(%{"Labels" => %{}}, ["job-1"]) == :orphan
      assert ContainerManager.orphan_status(%{}, ["job-1"]) == :orphan

      assert ContainerManager.orphan_status(
               %{"Labels" => %{"omashiki.job_scope_id" => ""}},
               ["job-1"]
             ) == :orphan
    end

    test "a container whose job is not active is an orphan" do
      container = %{"Labels" => %{"omashiki.job_scope_id" => "job-gone"}}

      assert ContainerManager.orphan_status(container, ["job-1", "job-2"]) == :orphan
      assert ContainerManager.orphan_status(container, []) == :orphan
    end

    test "a container whose job is active is not an orphan" do
      container = %{"Labels" => %{"omashiki.job_scope_id" => "job-1"}}

      assert ContainerManager.orphan_status(container, ["job-1"]) == :active
      assert ContainerManager.orphan_status(container, ["job-0", "job-1"]) == :active
    end

    test "the rule holds for the inspect shape as well as the list shape" do
      # /containers/json returns "Labels"; /containers/:id/json nests them
      # under "Config". Both feed cleanup_orphans, so both must classify.
      inspected = %{"Config" => %{"Labels" => %{"omashiki.job_scope_id" => "job-1"}}}

      assert ContainerManager.orphan_status(inspected, ["job-1"]) == :active
      assert ContainerManager.orphan_status(inspected, ["job-2"]) == :orphan
    end

    test "classification is total: a non-map container does not crash the sweep" do
      assert ContainerManager.job_scope_id_from_container(nil) == nil
      assert ContainerManager.job_scope_id_from_container("not-a-container") == nil
    end

    test "boot reclaims orphans" do
      # Read the application module's external-call table rather than its
      # source: this fails if the boot wiring is deleted, and keeps passing if
      # it is merely moved to another line or private helper.
      assert {ContainerManager, :cleanup_orphans, 0} in external_calls(Omashiki.Application),
             "Omashiki.Application no longer calls ContainerManager.cleanup_orphans/0 — " <>
               "containers abandoned by a crash would survive a restart forever."
    end
  end

  # -- reflection helpers ----------------------------------------------------

  # Every module compiled into :omashiki that declares at least one @callback.
  defp port_contracts do
    :omashiki
    |> Application.spec(:modules)
    |> Kernel.||([])
    |> Enum.filter(fn module ->
      Code.ensure_loaded?(module) and function_exported?(module, :behaviour_info, 1)
    end)
    |> Enum.sort()
  end

  # The contract surface of a behaviour: its own name, its callback specs, and
  # the public types those specs are written in. Deliberately excludes docs and
  # implementation.
  defp contract_surface(module) do
    Code.ensure_loaded!(module)

    callbacks =
      case Code.Typespec.fetch_callbacks(module) do
        {:ok, entries} ->
          for {{name, _arity}, definitions} <- entries, definition <- definitions do
            {"callback", name |> Code.Typespec.spec_to_quoted(definition) |> Macro.to_string()}
          end

        :error ->
          []
      end

    types =
      case Code.Typespec.fetch_types(module) do
        {:ok, entries} ->
          for {kind, definition} <- entries, kind in [:type, :opaque] do
            {"type", definition |> Code.Typespec.type_to_quoted() |> Macro.to_string()}
          end

        :error ->
          []
      end

    [{"module name", inspect(module)}] ++ callbacks ++ types
  end

  defp vendor_hits(text) do
    downcased = String.downcase(text)
    Enum.filter(@vendor_words, &String.contains?(downcased, &1))
  end

  # External calls recorded in the module's beam import table (ImpT).
  defp external_calls(module) do
    Code.ensure_loaded!(module)

    case :beam_lib.chunks(:code.which(module), [:imports]) do
      {:ok, {^module, [imports: imports]}} -> imports
      other -> flunk("could not read imports for #{inspect(module)}: #{inspect(other)}")
    end
  end
end
