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
  A short-lived container from `image` on `network` fetches `url`. The image is
  never pulled. `{:error, :no_http_client}` when it has neither curl nor python3.
  """
  @callback route(image :: String.t(), network :: String.t(), url :: String.t()) :: result()

  @doc "The host file at `origin` (absolute or `~/`) can be read."
  @callback readable(origin :: String.t()) :: result()

  @doc "The identity can mint an installation token."
  @callback identity(identity :: Omashiki.Config.Identity.t()) :: result()
end
