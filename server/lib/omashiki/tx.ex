defmodule Omashiki.Tx do
  @moduledoc false

  alias Omashiki.Repo

  @doc """
  `Repo.transaction/1` that maps deadlock and serialization failures to `{:error, :busy}`.
  """
  def run(fun) when is_function(fun, 0) do
    case Repo.transaction(fun) do
      {:error, %Postgrex.Error{} = error} -> busy_or_error(error)
      other -> other
    end
  rescue
    e in Postgrex.Error ->
      if busy_error?(e), do: {:error, :busy}, else: reraise(e, __STACKTRACE__)
  end

  defp busy_or_error(error) do
    if busy_error?(error), do: {:error, :busy}, else: {:error, error}
  end

  defp busy_error?(%Postgrex.Error{postgres: %{code: code}})
       when code in [:deadlock_detected, :serialization_failure],
       do: true

  defp busy_error?(_), do: false
end
