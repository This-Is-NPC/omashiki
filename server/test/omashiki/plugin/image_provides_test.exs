defmodule Omashiki.Plugin.ImageProvidesTest do
  use ExUnit.Case, async: false

  alias Omashiki.Config.Error
  alias Omashiki.Plugin.ImageProvides

  @moduletag :tmp_dir

  # A docker CLI that records its argv, prints `output`, and exits `status`.
  setup %{tmp_dir: tmp_dir} = ctx do
    argv = Path.join(tmp_dir, "argv")
    docker = Path.join(tmp_dir, "docker")
    status = Map.get(ctx, :status, 0)

    File.write!(docker, """
    #!/bin/sh
    printf '%s\\n' "$@" > #{argv}
    printf '%s' '#{Map.get(ctx, :output, "")}'
    exit #{status}
    """)

    File.chmod!(docker, 0o755)

    previous =
      Map.new([:plugin_image_provides, :docker_cli], &{&1, Application.get_env(:omashiki, &1)})

    Application.put_env(:omashiki, :plugin_image_provides, :inspect)
    Application.put_env(:omashiki, :docker_cli, docker)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:omashiki, key)
        {key, value} -> Application.put_env(:omashiki, key, value)
      end)
    end)

    %{argv: argv, image: "omashiki/agent:#{System.unique_integer([:positive])}"}
  end

  test "runs the image without pulling it", %{argv: argv, image: image} do
    assert :ok = ImageProvides.cover!(image, ["opencode"], [], "environments.opencode")

    args = argv |> File.read!() |> String.split("\n", trim: true)
    assert ["run", "--rm", "--pull", "never" | _] = args
    assert image in args
  end

  @tag status: 125,
       output: "docker: Error response from daemon: No such image: omashiki/agent:latest"
  test "a missing image names the image and how to provide it", %{image: image} do
    error =
      assert_raise Error, fn ->
        ImageProvides.cover!(image, ["opencode"], [], "environments.opencode")
      end

    assert Exception.message(error) =~ "image #{inspect(image)} is not on this machine"
    assert Exception.message(error) =~ "Omashiki never pulls images"
    assert Exception.message(error) =~ "docker pull #{image}"
  end

  @tag status: 1
  test "an image without the binaries is still a missing-binaries error", %{image: image} do
    assert_raise Error, ~r/does not provide \["opencode"\] \(docker exit 1\)/, fn ->
      ImageProvides.cover!(image, ["opencode"], [], "environments.opencode")
    end
  end
end
