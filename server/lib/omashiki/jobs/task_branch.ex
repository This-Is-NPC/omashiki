defmodule Omashiki.Jobs.TaskBranch do
  @moduledoc false

  alias Omashiki.Config.Registry

  @title_slug ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

  @doc "Resolve the persisted task branch from payload.branch or slug(payload.title)."
  def resolve(payload) when is_map(payload) do
    branch = Map.get(payload, "branch")
    title = Map.get(payload, "title")

    cond do
      is_binary(branch) and String.trim(branch) != "" ->
        validate_branch(String.trim(branch))

      is_binary(title) and String.trim(title) != "" ->
        title = String.trim(title)

        with :ok <- validate_title(title),
             {:ok, slug} <- slug_title(title) do
          {:ok, slug}
        end

      true ->
        {:error, :task_branch_required}
    end
  end

  def resolve(_), do: {:error, :task_branch_required}

  def validate_branch(branch) when is_binary(branch) do
    if Registry.valid_branch?(branch), do: {:ok, branch}, else: {:error, :invalid_branch}
  end

  def validate_title(title) when is_binary(title) do
    cond do
      String.contains?(title, "/") -> {:error, :invalid_title}
      String.trim(title) == "" -> {:error, :invalid_title}
      true -> :ok
    end
  end

  def slug_title(title) when is_binary(title) do
    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    if Regex.match?(@title_slug, slug), do: {:ok, slug}, else: {:error, :invalid_title_slug}
  end
end
