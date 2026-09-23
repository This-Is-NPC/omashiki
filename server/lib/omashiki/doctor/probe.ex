defmodule Omashiki.Doctor.Probe do
  @moduledoc """
  Everything `Omashiki.Doctor` observes outside its own arguments.

  The doctor decides what to check and what a result means; a probe only
  answers. `Omashiki.Doctor.HostProbe` asks the real host, tests pass fakes.
  """

  @type result :: :ok | {:error, term()}

  @doc "The container runtime answers."
  @callback runtime() :: result()

  @doc "The image is present locally. `{:error, :not_found}` when it is not."
  @callback image(image :: String.t()) :: result()

  @doc "The container network exists. `{:error, :not_found}` when it does not."
  @callback network(name :: String.t()) :: result()

  @doc "The house health endpoint answers from this host on `port`."
  @callback house(port :: pos_integer()) :: result()

  @doc """
  A short-lived container from `image` on `network` and the house reach each
  other: the house connects to the container, and the container fetches `url`.
  The image is never pulled. `{:error, {:blocked, [{direction, reason}]}}`
  names each direction that fails, `:to_house` or `:from_house`;
  `{:error, :no_python}` when the image has no python3.
  """
  @callback route(image :: String.t(), network :: String.t(), url :: String.t()) :: result()

  @doc "The host file at `origin` (absolute or `~/`) can be read."
  @callback readable(origin :: String.t()) :: result()

  @doc """
  The directory at `path` exists and this process can create files in it.
  `{:error, :enoent}` when nothing is there, `{:error, :enotdir}` when it is
  not a directory, the file system's reason when it refuses a new file.
  """
  @callback directory(path :: String.t()) :: result()

  @doc "The identity can mint an installation token."
  @callback identity(identity :: Omashiki.Config.Identity.t()) :: result()
end
