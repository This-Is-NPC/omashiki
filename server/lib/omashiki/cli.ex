defmodule Omashiki.Cli do
  @moduledoc """
  Runs an operator tool: `Omashiki.Cli.Token` or `Omashiki.Cli.Doctor`.

  A checkout reaches a tool through its Mix task. The release has no Mix, so
  `bin/token` and `bin/doctor` evaluate `run/2` through `bin/omashiki eval`.
  Both paths call `run/2`, so a tool starts the same processes and prints
  the same lines either way.
  """

  @doc "Starts only what the tool needs. The house may be running beside it."
  @callback start() :: :ok

  @doc "Runs the tool on `argv`. Returns the exit status and the text to print."
  @callback run(argv :: [String.t()]) :: {non_neg_integer(), String.t()}

  @doc """
  Starts `tool`, runs it on `argv`, and prints its output.

  Exits with `{:shutdown, status}` when the status is not zero, which both
  Mix and `bin/omashiki eval` turn into the process exit status.
  """
  @spec run(module(), [String.t()]) :: :ok
  def run(tool, argv) do
    :ok = Application.ensure_loaded(:omashiki)

    :ok = tool.start()
    {status, output} = tool.run(argv)
    IO.write(output)

    if status != 0, do: exit({:shutdown, status})
    :ok
  end
end
