defmodule Omashiki.Plugin.ImageProvides do
  @moduledoc """
  What a Docker image provides for plugin `requires.binaries`.

  `:plugin_image_provides` is `:inspect` (default, production), `:trust`
  (tests that never run Docker), a `%{image => [binary]}` map, or a
  1-arity function returning `:trust` or a list of binaries.
  """

  alias Omashiki.Config.Error

  @inspect_timeout_ms 30_000

  def cover!(image, required, packages, where)
      when is_binary(image) and is_list(required) and is_list(packages) do
    leftover =
      required
      |> Enum.reject(&(&1 in packages))

    if leftover == [] or has_binaries?(image, leftover) do
      :ok
    else
      raise Error,
            "#{where}: plugin requires.binaries #{inspect(leftover)} not covered by packages or image #{inspect(image)}"
    end
  end

  defp has_binaries?(image, binaries) do
    case source() do
      :trust ->
        true

      :inspect ->
        inspect_docker!(image, binaries)

      map when is_map(map) ->
        provided = Map.get(map, image, [])
        Enum.all?(binaries, &(&1 in provided))

      fun when is_function(fun, 1) ->
        case fun.(image) do
          :trust -> true
          list when is_list(list) -> Enum.all?(binaries, &(&1 in list))
          _ -> false
        end
    end
  end

  defp source do
    Application.get_env(:omashiki, :plugin_image_provides, :inspect)
  end

  defp inspect_docker!(image, binaries) do
    key = {:omashiki_plugin_image_provides, image, binaries}

    case :persistent_term.get(key, :miss) do
      true ->
        true

      :miss ->
        result = do_inspect_docker!(image, binaries)
        :persistent_term.put(key, true)
        result
    end
  end

  defp do_inspect_docker!(image, binaries) do
    script =
      binaries
      |> Enum.map(&"command -v #{shell_escape(&1)} >/dev/null")
      |> Enum.join(" && ")

    args = ["run", "--rm", "--network", "none", "--entrypoint", "sh", image, "-c", script]
    task = Task.async(fn -> System.cmd("docker", args, stderr_to_stdout: true) end)

    case Task.yield(task, @inspect_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0}} ->
        true

      {:ok, {output, status}} ->
        raise Error,
              "image #{inspect(image)} does not provide #{inspect(binaries)} (docker exit #{status}): #{String.slice(to_string(output), 0, 512)}"

      nil ->
        raise Error, "timed out inspecting image #{inspect(image)} for #{inspect(binaries)}"
    end
  rescue
    error in Error ->
      reraise error, __STACKTRACE__

    error ->
      raise Error, "failed to inspect image #{inspect(image)}: #{Exception.message(error)}"
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
