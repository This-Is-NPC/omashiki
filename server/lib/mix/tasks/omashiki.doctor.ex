defmodule Mix.Tasks.Omashiki.Doctor do
  @moduledoc """
  Diagnoses the installation against `omashiki.toml`.

      mix omashiki.doctor

  Runs every `Omashiki.Doctor` check, the container route check included,
  and prints one line per check with its fix. Exits non-zero when any check
  is an error. The task starts no endpoint of its own; the route check needs
  the house running and reports a warning when it is not.
  """

  use Mix.Task

  @shortdoc "Diagnose Docker, images, agent network, credentials, and identities."

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started([:ssl, :mint, :telemetry])

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

    Enum.each(checks, &print/1)

    if Omashiki.Doctor.worst(checks) == :error do
      exit({:shutdown, 1})
    end
  end

  defp print(check) do
    status = check.status |> Atom.to_string() |> String.pad_trailing(5)
    Mix.shell().info("#{status}  #{check.id}  #{check.summary}")
    if check.fix, do: Mix.shell().info("       fix: #{check.fix}")
  end
end
