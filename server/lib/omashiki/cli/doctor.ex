defmodule Omashiki.Cli.Doctor do
  @moduledoc """
  Diagnoses the installation against `omashiki.toml`.

  Run it as `mix omashiki.doctor` in a checkout and as `bin/doctor` in the
  release. It takes no arguments.

  Runs every `Omashiki.Doctor` check, the container route check included,
  and prints one line per check with its fix. Exits non-zero when any check
  is an error. The tool starts no endpoint of its own; the route check needs
  the house running and reports a warning when it is not.
  """

  @behaviour Omashiki.Cli

  @impl Omashiki.Cli
  def start do
    {:ok, _} = Application.ensure_all_started([:ssl, :mint, :telemetry])
    :ok
  end

  @impl Omashiki.Cli
  def run(_argv) do
    # The doctor checks images itself. Inspecting them during the load would
    # turn a missing image into a config error before the doctor could name it.
    Application.put_env(:omashiki, :plugin_image_provides, :trust)

    checks =
      try do
        Omashiki.Config.load!()
        Omashiki.Doctor.run(route: true)
      rescue
        error in Omashiki.Config.Error ->
          [
            %{
              id: "config",
              status: :error,
              summary: Exception.message(error),
              fix: "Correct omashiki.toml, then run the doctor again."
            }
          ]
      end

    status = if Omashiki.Doctor.worst(checks) == :error, do: 1, else: 0
    {status, Enum.map_join(checks, &line/1)}
  end

  defp line(check) do
    status = check.status |> Atom.to_string() |> String.pad_trailing(5)
    fix = if check.fix, do: "       fix: #{check.fix}\n", else: ""
    "#{status}  #{check.id}  #{check.summary}\n" <> fix
  end
end
