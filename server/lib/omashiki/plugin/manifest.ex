defmodule Omashiki.Plugin.Manifest do
  @moduledoc false
  alias Omashiki.Config.Error
  alias Omashiki.Plugin.OptionSchema

  @legacy ~w(isolation runtime sink adapter harness)
  @vars ~w(instruction invocation_path runner_path model timeout_ms reasoning_effort PORT gateway_base_url gateway_token gateway_model credentials_path config_path auth_path gateway_auth_path item)
  @shapes ~w(object jsonl_agent_end result_envelope)
  @transports ~w(cli http)
  @prepare_modes ~w(gateway_prompt invocation_json opencode_gateway opencode_host none)

  defstruct [
    :name,
    :path,
    :contents,
    :digest,
    :transport,
    :readiness,
    :prepare,
    :argv,
    :env,
    :files,
    :output,
    :options,
    :requires,
    :llm_egress,
    http: nil,
    option_argv: []
  ]

  def parse!(name, path, contents) do
    case Toml.decode(contents) do
      {:ok, map} -> build(name, path, contents, stringify(map), path)
      {:error, reason} -> raise Error, "#{path}: unreadable plugin manifest: #{inspect(reason)}"
    end
  end

  def snapshot(%__MODULE__{} = m) do
    Map.new([
      {"name", m.name},
      {"path", m.path},
      {"contents", m.contents},
      {"digest", m.digest},
      {"transport", m.transport},
      {"readiness", m.readiness},
      {"prepare", m.prepare},
      {"argv", m.argv},
      {"env", m.env},
      {"files", m.files},
      {"output", m.output},
      {"options", m.options},
      {"requires", m.requires},
      {"llm_egress", m.llm_egress && Atom.to_string(m.llm_egress)},
      {"http", m.http},
      {"option_argv", m.option_argv}
    ])
  end

  def from_snapshot(%{"name" => name} = map) do
    struct!(__MODULE__, %{
      name: name,
      path: Map.get(map, "path"),
      contents: Map.get(map, "contents", ""),
      digest: Map.get(map, "digest"),
      transport: Map.fetch!(map, "transport"),
      readiness: Map.get(map, "readiness", %{"kind" => "none"}),
      prepare: Map.get(map, "prepare", "none"),
      argv: Map.get(map, "argv", %{}),
      env: Map.get(map, "env", %{}),
      files: Map.get(map, "files", %{}),
      output: Map.fetch!(map, "output"),
      options: Map.get(map, "options", %{}),
      requires: Map.get(map, "requires", %{}),
      llm_egress: egress(Map.get(map, "llm_egress")),
      http: Map.get(map, "http"),
      option_argv: Map.get(map, "option_argv", [])
    })
  end

  def admitted_snapshot(%__MODULE__{path: path, contents: contents, digest: digest}) do
    %{"path" => path, "contents" => contents, "digest" => digest}
  end

  defp build(name, path, contents, attrs, where) do
    for key <- @legacy, Map.has_key?(attrs, key) do
      raise Error, "#{where}: unknown field #{inspect(key)}"
    end

    transport = req!(attrs, "transport", where)
    if transport not in @transports, do: raise(Error, "#{where}.transport invalid")

    prepare = Map.get(attrs, "prepare", "none")
    if prepare not in @prepare_modes, do: raise(Error, "#{where}.prepare invalid")

    output = output!(Map.get(attrs, "output"), where)
    argv = stringify(Map.get(attrs, "argv", %{}))
    check_templates!(Map.get(argv, "template"), where <> ".argv.template")

    options = options!(Map.get(attrs, "options", %{}), where)
    files = files!(Map.get(attrs, "files", %{}), where)

    manifest = %__MODULE__{
      name: name,
      path: path,
      contents: contents,
      digest: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower),
      transport: transport,
      readiness: readiness!(Map.get(attrs, "readiness", "none"), where),
      prepare: prepare,
      argv: argv,
      env: env!(Map.get(attrs, "env", %{}), where),
      files: files,
      output: output,
      options: options,
      requires: %{
        "binaries" => Map.get(stringify(Map.get(attrs, "requires", %{})), "binaries", [])
      },
      llm_egress: egress(Map.get(attrs, "llm_egress")),
      http: if(transport == "http", do: stringify(Map.get(attrs, "http", %{}))),
      option_argv: option_argv!(Map.get(attrs, "option_argv", []), where)
    }

    OptionSchema.validate_schema!(manifest, where)
    manifest
  end

  defp options!(table, w) when is_map(table) do
    table
    |> stringify()
    |> Enum.map(fn {name, spec} ->
      spec_where = w <> ".options." <> name
      spec = stringify(spec)

      unless Map.has_key?(spec, "type") do
        raise Error, spec_where <> ".type required"
      end

      {name, spec}
    end)
    |> Map.new()
  end

  defp options!(_, w), do: raise(Error, w <> ".options must be a table")

  defp files!(table, w) when is_map(table) do
    table
    |> stringify()
    |> Enum.map(fn {name, spec} ->
      spec_where = w <> ".files." <> name
      spec = stringify(spec)
      path = req!(spec, "path", spec_where)
      body = req!(spec, "body", spec_where)
      check_template!(path, spec_where <> ".path")
      check_template!(body, spec_where <> ".body")
      {name, %{"path" => path, "body" => body}}
    end)
    |> Map.new()
  end

  defp files!(_, w), do: raise(Error, w <> ".files must be a table")

  defp output!(nil, w), do: raise(Error, "#{w}.output required")

  defp output!(table, w) do
    table = stringify(table)
    shape = req!(table, "shape", w <> ".output")
    if shape not in @shapes, do: raise(Error, "#{w}.output.shape invalid")
    Map.update(table, "usage", %{}, &stringify/1)
  end

  defp readiness!("none", _), do: %{"kind" => "none"}
  defp readiness!(bin, w) when is_binary(bin), do: readiness!(%{"kind" => bin}, w)

  defp readiness!(%{"kind" => "exec"} = t, w) do
    argv = Map.get(t, "argv") || raise(Error, "#{w}.readiness.argv required")
    check_templates!(argv, w <> ".readiness.argv")
    %{"kind" => "exec", "argv" => argv, "timeout_ms" => Map.get(t, "timeout_ms", 10_000)}
  end

  defp readiness!(%{"kind" => "http"} = t, w) do
    %{
      "kind" => "http",
      "path" => req!(t, "path", w),
      "timeout_ms" => Map.get(t, "timeout_ms", 60_000)
    }
  end

  defp readiness!(%{"kind" => kind}, _) when kind in ["none", "exec", "http"],
    do: %{"kind" => kind}

  defp readiness!(other, w), do: raise(Error, "#{w}.readiness invalid: #{inspect(other)}")

  defp env!(table, w) do
    stringify(table)
    |> Enum.map(fn
      {k, v} when is_binary(v) ->
        check_template!(v, w <> ".env." <> k)
        {k, v}

      {k, nested} when is_map(nested) ->
        nested =
          stringify(nested)
          |> Enum.map(fn {nk, nv} ->
            check_template!(nv, w <> ".env." <> k <> "." <> nk)
            {nk, nv}
          end)
          |> Map.new()

        {k, nested}

      {k, _} ->
        raise Error, "#{w}.env." <> k <> " must be string or table"
    end)
    |> Map.new()
  end

  defp option_argv!(list, w) when is_list(list) do
    Enum.map(list, fn entry ->
      entry = stringify(entry)
      check_templates!(Map.get(entry, "append", []), w <> ".option_argv")
      entry
    end)
  end

  defp option_argv!(_, w), do: raise(Error, "#{w}.option_argv must be array")

  defp check_templates!(list, w) when is_list(list), do: Enum.each(list, &check_template!(&1, w))
  defp check_templates!(nil, _), do: :ok

  defp check_template!(template, w) when is_binary(template) do
    for [_, var] <- Regex.scan(~r/\{\{([a-z_]+)\}\}/, template), var not in @vars do
      raise Error, w <> ": unknown template variable {{#{var}}}"
    end
  end

  defp req!(map, key, where) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> v
      _ -> raise Error, where <> "." <> key <> " required"
    end
  end

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp egress(nil), do: nil
  defp egress("gateway"), do: :gateway
  defp egress("engine"), do: :engine
  defp egress(other), do: other
end
