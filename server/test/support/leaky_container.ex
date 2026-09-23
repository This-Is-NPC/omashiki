defmodule Omashiki.LeakyContainer do
  @moduledoc """
  A runner container that provisions the real artifact of the environment's
  sink and writes a GitHub token into it, as a careless agent would. Its
  finalization is the production one, so the secret scan refuses the output.
  """

  alias Omashiki.Jobs.{GitArtifact, WorkArtifact}
  alias Omashiki.Jobs.Runner.DockerContainer

  @doc "The token written to `leak.txt`."
  def leak, do: "ghp_" <> "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8"

  def provision(job, attempt, environment, opts) do
    write_leak = fn artifact ->
      File.write!(Path.join(artifact.path, "leak.txt"), "export GH=#{leak()}\n")
      {:ok, %{id: "leaky-container"}}
    end

    case environment["sink"] do
      "git" -> GitArtifact.provision(job, attempt, opts, write_leak)
      sink -> WorkArtifact.provision(job, sink, opts, write_leak)
    end
  end

  def exec(_container, _argv, _timeout_ms), do: {:ok, %{exit_status: 0, output: ""}}

  defdelegate finalize(container, job, opts), to: DockerContainer

  def destroy(%{artifact: %{branch: _} = artifact} = container),
    do: GitArtifact.cleanup(artifact, preserve_branch: Map.get(container, :preserve_artifact))

  def destroy(%{artifact: artifact}), do: WorkArtifact.cleanup(artifact)
  def destroy(_container), do: :ok
end
