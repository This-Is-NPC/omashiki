defmodule Mix.Tasks.Omashiki.Users.ResetPassword do
  @moduledoc """
  Resets the password for an Omashiki user.

      mix omashiki.users.reset_password <username_or_email>

  Prompts for the new password twice (echo off) and writes the new
  Argon2id hash. Refuses to run if the identifier does not match a user.
  """

  use Mix.Task

  @shortdoc "Reset an Omashiki user's password (interactive)."

  @impl Mix.Task
  def run([identifier]) when is_binary(identifier) and identifier != "" do
    Mix.Task.run("app.start")

    new = prompt("New password: ")
    confirm = prompt("Confirm password: ")

    case reset_password(identifier, new, confirm) do
      {:ok, user} ->
        Mix.shell().info("Password updated for #{user.username} <#{user.email}>.")

      {:error, :no_such_user} ->
        Mix.shell().error("No user with identifier #{inspect(identifier)} found.")
        exit({:shutdown, 1})

      {:error, :passwords_do_not_match} ->
        Mix.shell().error("Passwords do not match.")
        exit({:shutdown, 1})

      {:error, %Ecto.Changeset{} = changeset} ->
        Mix.shell().error("Validation failed: #{inspect(changeset.errors)}")
        exit({:shutdown, 1})
    end
  end

  def run(_args) do
    Mix.shell().error("Usage: mix omashiki.users.reset_password <username_or_email>")
    exit({:shutdown, 1})
  end

  @doc """
  Headless variant suitable for tests. Returns the same shape as the
  task itself emits — `{:ok, user}` or one of the error tuples — without
  consulting `:io.get_password/1`.
  """
  @spec reset_password(String.t(), String.t(), String.t()) ::
          {:ok, Omashiki.Accounts.User.t()}
          | {:error, :no_such_user | :passwords_do_not_match | Ecto.Changeset.t()}
  def reset_password(identifier, new, confirm) do
    cond do
      new != confirm ->
        {:error, :passwords_do_not_match}

      true ->
        case Omashiki.Accounts.get_user_by_identifier(identifier) do
          nil ->
            {:error, :no_such_user}

          user ->
            Omashiki.Accounts.update_password(user, new)
        end
    end
  end

  defp prompt(label) do
    case :io.get_password(label) do
      :eof ->
        ""

      pw when is_list(pw) ->
        List.to_string(pw) |> String.trim()

      pw when is_binary(pw) ->
        String.trim(pw)
    end
  end
end
