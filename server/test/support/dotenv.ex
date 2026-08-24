defmodule Omashiki.Test.Dotenv do
  @moduledoc """
  Minimal `.env` loader used by `test_helper.exs`.

  Reads `server/.env` (if present) and sets every `KEY=value` line as a
  process environment variable via `System.put_env/2`. Already-set variables
  are preserved (so CI overrides win).

  Intentionally does **not** expand shell variables, handle multiline values,
  or support `export` prefixes — keep the file boring.
  """

  @doc """
  Loads `path` into the process environment. Returns `{:ok, n}` with the
  number of variables loaded, or `:not_found` when the file is absent.
  """
  def load(path) do
    case File.read(path) do
      {:ok, contents} ->
        count =
          contents
          |> String.split("\n")
          |> Enum.reduce(0, fn line, acc ->
            case parse_line(line) do
              {:ok, key, value} ->
                if System.get_env(key) in [nil, ""] do
                  System.put_env(key, value)
                end

                acc + 1

              :skip ->
                acc
            end
          end)

        {:ok, count}

      {:error, :enoent} ->
        :not_found
    end
  end

  defp parse_line(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" -> :skip
      String.starts_with?(trimmed, "#") -> :skip
      true -> split_kv(trimmed)
    end
  end

  defp split_kv(line) do
    case String.split(line, "=", parts: 2) do
      [k, v] ->
        key = k |> String.trim() |> strip_export()
        value = v |> String.trim() |> strip_quotes()

        if key == "", do: :skip, else: {:ok, key, value}

      _ ->
        :skip
    end
  end

  defp strip_export("export " <> rest), do: String.trim(rest)
  defp strip_export(key), do: key

  defp strip_quotes(<<?", rest::binary>>) do
    case String.ends_with?(rest, "\"") do
      true -> String.slice(rest, 0..(byte_size(rest) - 2))
      false -> "\"" <> rest
    end
  end

  defp strip_quotes(<<?', rest::binary>>) do
    case String.ends_with?(rest, "'") do
      true -> String.slice(rest, 0..(byte_size(rest) - 2))
      false -> "'" <> rest
    end
  end

  defp strip_quotes(value), do: value
end
