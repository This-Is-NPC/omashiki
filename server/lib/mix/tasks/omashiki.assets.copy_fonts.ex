defmodule Mix.Tasks.Omashiki.Assets.CopyFonts do
  @moduledoc """
  Copies the `@fontsource` woff/woff2 files referenced from
  `assets/css/app.css` into `priv/static/assets/files/` so the browser
  finds them at the relative URLs Tailwind emits.

  Tailwind's @import resolves the imported CSS at build time but does
  NOT bundle/copy the `url(./files/<name>.woff2)` assets — they stay as
  relative paths in the merged `app.css`. Without this task the browser
  hits 404 for every font weight.

  Idempotent. Re-runs only re-copy files whose mtime moved.

  Run automatically via the `assets.build` / `assets.deploy` aliases.
  """

  use Mix.Task

  @shortdoc "Copy @fontsource woff(2) files into priv/static/assets/files/"

  @families ~w(newsreader inter space-grotesk)
  @source_root "assets/node_modules/@fontsource"
  @dest_root "priv/static/assets/files"

  @impl Mix.Task
  def run(_args) do
    File.mkdir_p!(@dest_root)

    {copied, skipped} =
      Enum.reduce(@families, {0, 0}, fn family, {c, s} ->
        files_dir = Path.join([@source_root, family, "files"])

        if File.dir?(files_dir) do
          files_dir
          |> File.ls!()
          |> Enum.filter(&font_file?/1)
          |> Enum.reduce({c, s}, fn name, {cc, ss} ->
            src = Path.join(files_dir, name)
            dst = Path.join(@dest_root, name)

            if needs_copy?(src, dst) do
              File.cp!(src, dst)
              {cc + 1, ss}
            else
              {cc, ss + 1}
            end
          end)
        else
          {c, s}
        end
      end)

    Mix.shell().info(
      "[omashiki.assets.copy_fonts] copied=#{copied} skipped=#{skipped} -> #{@dest_root}"
    )

    :ok
  end

  defp font_file?(name) do
    String.ends_with?(name, [".woff2", ".woff"])
  end

  defp needs_copy?(src, dst) do
    case File.stat(dst) do
      {:ok, %{mtime: dst_mtime}} ->
        case File.stat(src) do
          {:ok, %{mtime: src_mtime}} -> src_mtime > dst_mtime
          _ -> true
        end

      _ ->
        true
    end
  end
end
