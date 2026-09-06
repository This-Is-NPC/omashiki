defmodule Omashiki.Worker.Enroll do
  @moduledoc false

  alias Omashiki.Worker.{Poller, State}

  @doc "Configured enroll listener TCP port."
  @spec port() :: pos_integer()
  def port do
    Application.get_env(:omashiki, :enroll_port, 4012)
  end

  @doc "True when an enroll shared secret is configured."
  @spec secret_configured?() :: boolean()
  def secret_configured? do
    case secret() do
      secret when is_binary(secret) and secret != "" -> true
      _ -> false
    end
  end

  @doc "Validate a presented enroll bearer token."
  @spec valid_secret?(String.t() | nil) :: boolean()
  def valid_secret?(plaintext) when is_binary(plaintext) do
    case secret() do
      secret when is_binary(secret) and secret != "" ->
        byte_size(secret) == byte_size(plaintext) and
          Plug.Crypto.secure_compare(secret, plaintext)

      _ ->
        false
    end
  end

  def valid_secret?(_), do: false

  @doc """
  Enroll one house: persist its entry (replacing a previous one with the same
  id) and reconfigure the poll loop over every enrolled house.
  """
  @spec enroll(map()) :: :ok | {:error, term()}
  def enroll(params) when is_map(params) do
    case State.enroll(params) do
      {:ok, _managers} -> Poller.configure()
      :error -> {:error, :invalid_body}
    end
  end

  @doc "Forget one house by id and stop polling it. Other houses are untouched."
  @spec unenroll(String.t()) :: :ok | {:error, term()}
  def unenroll(id) when is_binary(id) and id != "" do
    case State.remove(id) do
      {:ok, _managers} -> Poller.configure()
      :error -> {:error, :state_unwritable}
    end
  end

  def unenroll(_), do: {:error, :invalid_id}

  @doc "Enrolled houses without their tokens."
  @spec list() :: [%{id: String.t(), url: String.t()}]
  def list do
    Enum.map(State.managers(), &Map.take(&1, [:id, :url]))
  end

  defp secret do
    Application.get_env(:omashiki, :enroll_secret) || System.get_env("OMASHIKI_ENROLL_SECRET")
  end
end
