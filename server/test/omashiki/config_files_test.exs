defmodule Omashiki.ConfigFilesTest do
  @moduledoc """
  The live file stays the source of truth.

  Every property here is one of two promises: the live path is always a copy
  of the applied document, so boot needs nothing else; and no content is ever
  lost, whether it was replaced by a save, an apply, a restore, or an edit made
  outside Omashiki.
  """

  use ExUnit.Case, async: false

  alias Omashiki.Accounts.User
  alias Omashiki.Config
  alias Omashiki.ConfigFiles
  alias OmashikiWeb.TaskViews
  import Omashiki.Fixtures

  @ada %User{username: "ada"}
  @views """
  [[views]]
  name = "mine"
  title = "Mine"
  """

  setup do
    Config.reset!()
    root = Path.join(System.tmp_dir!(), "omashiki-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    copy_plugins!(root)
    assert {_output, 0} = System.cmd("git", ["init", "--quiet", Path.join(root, "repo")])

    path = Path.join(root, "omashiki.toml")
    views = Path.join(root, "ui.toml")
    File.write!(path, house_toml())
    previous = Map.new([:config_path, :ui_config_path], &{&1, Application.get_env(:omashiki, &1)})
    Application.put_env(:omashiki, :config_path, path)
    Application.put_env(:omashiki, :ui_config_path, views)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:omashiki, key)
        {key, value} -> Application.put_env(:omashiki, key, value)
      end)

      Config.reset!()
      File.rm_rf!(root)
    end)

    %{root: root, path: path, views: views, store: Path.join(root, ".omashiki-files")}
  end

  describe "the store" do
    test "imports the live file as the applied document on first use", ctx do
      assert %{applied: "omashiki", drift?: false, documents: [doc], read_only: nil} =
               ConfigFiles.list(:config)

      assert %{name: "omashiki", applied?: true, piece?: false, path: path} = doc
      assert path == ctx.path
      assert File.read!(Path.join(ctx.store, "config/omashiki.toml")) == house_toml()
      assert {:ok, %{content: content, hash: hash}} = ConfigFiles.read(:config, "omashiki")
      assert content == house_toml()
      assert hash == doc.hash
    end

    test "starts empty when there is no live file yet", _ctx do
      assert %{applied: nil, drift?: false, documents: []} = ConfigFiles.list(:views)
    end

    test "reports an outside edit, then adopts it and keeps the old content", ctx do
      ConfigFiles.list(:config)
      edited = house_toml(model: "edited-outside")
      File.write!(ctx.path, edited)

      assert %{drift?: true} = ConfigFiles.list(:config)
      assert {:ok, %{content: ^edited}} = ConfigFiles.read(:config, "omashiki")
      assert %{drift?: false} = ConfigFiles.list(:config)

      assert [%{author: nil, hash: hash}] = ConfigFiles.history(:config, "omashiki")
      assert hash == sha(house_toml())
    end
  end

  describe "drafts" do
    test "save while invalid and never touch the live file", ctx do
      assert {:ok, %{name: "next", applied?: false, path: path, hash: hash}} =
               ConfigFiles.create(:config, "next", from: "omashiki", author: @ada)

      assert path == Path.join(ctx.store, "config/next.toml")

      assert {:ok, %{document: doc, reload: nil}} =
               ConfigFiles.save(:config, "next", "not [ toml", hash, author: @ada)

      assert doc.hash == sha("not [ toml")
      assert File.read!(ctx.path) == house_toml()
    end

    test "start blank or from another document", _ctx do
      assert {:ok, _doc} = ConfigFiles.create(:config, "empty", from: :blank, author: @ada)
      assert {:ok, %{content: ""}} = ConfigFiles.read(:config, "empty")
      assert {:error, :not_found} = ConfigFiles.create(:config, "x", from: "nope", author: @ada)
    end

    test "refuse a stale hash", _ctx do
      {:ok, doc} = ConfigFiles.create(:config, "next", from: "omashiki", author: @ada)
      assert {:ok, _doc} = ConfigFiles.save(:config, "next", "a = 1\n", doc.hash, author: @ada)

      assert {:error, :changed} =
               ConfigFiles.save(:config, "next", "a = 2\n", doc.hash, author: @ada)

      assert {:ok, %{content: "a = 1\n"}} = ConfigFiles.read(:config, "next")
    end
  end

  describe "apply" do
    setup ctx do
      assert :ok = Config.load!(ctx.path)
      :ok
    end

    test "writes the live file, marks it applied and reloads the house", ctx do
      {:ok, doc} = ConfigFiles.create(:config, "next", from: "omashiki", author: @ada)
      next = house_toml(model: "new-model")
      {:ok, _doc} = ConfigFiles.save(:config, "next", next, doc.hash, author: @ada)
      generation = Config.generation()

      assert {:ok, %{document: %{name: "next", applied?: true}, reload: {:ok, info}}} =
               ConfigFiles.apply(:config, "next", author: @ada)

      assert info.generation == generation + 1
      assert [%{model: "new-model"}] = Config.credentials()
      assert File.read!(ctx.path) == next
      assert %{applied: "next", drift?: false} = ConfigFiles.list(:config)

      # The live content the apply replaced, so restoring it undoes the apply.
      assert [%{hash: hash, author: "ada"} | _] = ConfigFiles.history(:config, "next")
      assert hash == sha(house_toml())
    end

    test "rejects an invalid document and changes nothing", ctx do
      {:ok, doc} = ConfigFiles.create(:config, "next", from: "omashiki", author: @ada)
      {:ok, _doc} = ConfigFiles.save(:config, "next", "not [ toml", doc.hash, author: @ada)
      generation = Config.generation()

      assert {:error, {:invalid, message}} = ConfigFiles.apply(:config, "next", author: @ada)
      assert message =~ "unreadable"
      assert File.read!(ctx.path) == house_toml()
      assert %{applied: "omashiki"} = ConfigFiles.list(:config)
      assert Config.generation() == generation
    end

    test "validates a draft as if it were at the live path", ctx do
      assert {:error, message} = ConfigFiles.validate(:config, "not [ toml")
      assert message =~ ctx.path
      assert {:ok, %{restart_required: []}} = ConfigFiles.validate(:config, house_toml())
    end

    test "points a decode error at its line", _ctx do
      assert {:error, message} = ConfigFiles.validate(:config, "a = 1\nnot [ toml\n")
      assert ConfigFiles.error_lines(:config, "omashiki", message) == [2]
      assert ConfigFiles.error_lines(:config, "next", message) == [2]

      assert {:error, message} =
               ConfigFiles.validate(:config, String.replace(house_toml(), "[limits]", "[limitz]"))

      assert ConfigFiles.error_lines(:config, "omashiki", message) == []
    end
  end

  describe "the applied document" do
    setup ctx do
      assert :ok = Config.load!(ctx.path)
      {:ok, %{hash: hash}} = ConfigFiles.read(:config, "omashiki")
      %{hash: hash}
    end

    test "saves through validation, the live file and a reload", ctx do
      next = house_toml(model: "saved-model")

      assert {:ok, %{document: %{applied?: true}, reload: {:ok, _info}}} =
               ConfigFiles.save(:config, "omashiki", next, ctx.hash, author: @ada)

      assert File.read!(ctx.path) == next
      assert [%{model: "saved-model"}] = Config.credentials()
    end

    test "rejects invalid content without writing", ctx do
      assert {:error, {:invalid, _message}} =
               ConfigFiles.save(:config, "omashiki", "not [ toml", ctx.hash, author: @ada)

      assert File.read!(ctx.path) == house_toml()
    end

    test "refuses to overwrite an outside edit", ctx do
      File.write!(ctx.path, house_toml(model: "outside"))

      assert {:error, :changed_on_disk} =
               ConfigFiles.save(:config, "omashiki", house_toml(), ctx.hash, author: @ada)

      assert File.read!(ctx.path) == house_toml(model: "outside")
    end
  end

  describe "pieces" do
    setup ctx do
      piece = Path.join(ctx.root, "pieces/credentials.toml")
      File.mkdir_p!(Path.dirname(piece))
      File.write!(piece, credential_toml("piece-model"))
      File.write!(ctx.path, ~s(include = ["pieces"]\n) <> house_toml(credentials: false))
      assert :ok = Config.load!(ctx.path)
      %{piece: piece}
    end

    test "are listed by include path and read from disk", ctx do
      assert %{documents: [_root, piece]} = ConfigFiles.list(:config)
      assert %{name: "pieces/credentials.toml", piece?: true, path: path} = piece
      assert path == ctx.piece

      assert {:ok, %{content: content}} = ConfigFiles.read(:config, "pieces/credentials.toml")
      assert content == credential_toml("piece-model")
    end

    test "save validates the root with the piece replaced, then reloads", ctx do
      {:ok, %{hash: hash}} = ConfigFiles.read(:config, "pieces/credentials.toml")

      assert {:error, {:invalid, message}} =
               ConfigFiles.save(:config, "pieces/credentials.toml", "[limits]\n", hash,
                 author: @ada
               )

      assert message =~ "[limits] must stay in omashiki.toml"
      assert File.read!(ctx.piece) == credential_toml("piece-model")

      assert {:ok, %{document: %{piece?: true}, reload: {:ok, _info}}} =
               ConfigFiles.save(:config, "pieces/credentials.toml", credential_toml("new"), hash,
                 author: @ada
               )

      assert [%{model: "new"}] = Config.credentials()
      assert [%{author: "ada"}] = ConfigFiles.history(:config, "pieces/credentials.toml")

      assert {:error, :changed_on_disk} =
               ConfigFiles.save(:config, "pieces/credentials.toml", "", hash, author: @ada)
    end

    test "point a decode error at the piece, not the root", _ctx do
      piece = "pieces/credentials.toml"
      assert {:error, message} = ConfigFiles.validate(:config, "x = 1\nnot [ toml\n", piece)
      assert ConfigFiles.error_lines(:config, piece, message) == [2]
      assert ConfigFiles.error_lines(:config, "omashiki", message) == []
    end

    test "are neither applied nor deleted", _ctx do
      assert {:error, :piece} =
               ConfigFiles.apply(:config, "pieces/credentials.toml", author: @ada)

      assert {:error, :piece} =
               ConfigFiles.delete(:config, "pieces/credentials.toml", author: @ada)
    end
  end

  describe "history" do
    test "keeps the last 50 versions", _ctx do
      {:ok, doc} = ConfigFiles.create(:config, "next", from: :blank, author: @ada)

      Enum.reduce(1..55, doc.hash, fn n, hash ->
        {:ok, %{document: doc}} =
          ConfigFiles.save(:config, "next", "n = #{n}\n", hash, author: @ada)

        doc.hash
      end)

      versions = ConfigFiles.history(:config, "next")
      assert length(versions) == 50
      assert hd(versions).hash == sha("n = 54\n")
      assert List.last(versions).hash == sha("n = 5\n")
    end

    test "restore puts a version back and records what it replaced", _ctx do
      {:ok, doc} = ConfigFiles.create(:config, "next", from: :blank, author: @ada)

      {:ok, %{document: doc}} =
        ConfigFiles.save(:config, "next", "first = 1\n", doc.hash, author: @ada)

      {:ok, %{document: doc}} =
        ConfigFiles.save(:config, "next", "second = 2\n", doc.hash, author: @ada)

      [%{id: id, hash: hash} | _] = ConfigFiles.history(:config, "next")
      assert hash == sha("first = 1\n")

      assert {:ok, %{document: %{hash: ^hash}}} =
               ConfigFiles.restore(:config, "next", id, doc.hash, author: @ada)

      assert {:ok, %{content: "first = 1\n"}} = ConfigFiles.read(:config, "next")
      assert [%{hash: newest} | _] = ConfigFiles.history(:config, "next")
      assert newest == sha("second = 2\n")

      assert {:error, :changed} = ConfigFiles.restore(:config, "next", id, doc.hash, author: @ada)

      assert {:error, :not_found} =
               ConfigFiles.restore(:config, "next", "../x", hash, author: @ada)
    end
  end

  describe "delete" do
    test "removes a draft and its history, never the applied document", ctx do
      {:ok, doc} = ConfigFiles.create(:config, "next", from: "omashiki", author: @ada)
      {:ok, _doc} = ConfigFiles.save(:config, "next", "a = 1\n", doc.hash, author: @ada)

      assert :ok = ConfigFiles.delete(:config, "next", author: @ada)
      assert {:error, :not_found} = ConfigFiles.read(:config, "next")
      refute File.exists?(Path.join(ctx.store, "config/history/documents/next"))

      assert {:error, :applied} = ConfigFiles.delete(:config, "omashiki", author: @ada)
      assert {:error, :not_found} = ConfigFiles.delete(:config, "next", author: @ada)
    end
  end

  describe "names and paths" do
    test "reject names outside the pattern and names already taken", _ctx do
      for name <- ["Bad", "../omashiki", "-x", String.duplicate("a", 41), "a.b", nil] do
        assert {:error, :invalid_name} =
                 ConfigFiles.create(:config, name, from: :blank, author: @ada)
      end

      assert {:error, :exists} =
               ConfigFiles.create(:config, "omashiki", from: :blank, author: @ada)

      assert {:error, :not_found} = ConfigFiles.read(:config, "../omashiki")
      assert {:error, :not_found} = ConfigFiles.read(:config, "omashiki.toml")
    end

    test "never write through a symlinked live file", ctx do
      target = Path.join(ctx.root, "elsewhere.toml")
      File.write!(target, @views)
      File.ln_s!(target, ctx.views)

      assert %{applied: "ui"} = ConfigFiles.list(:views)
      {:ok, %{hash: hash}} = ConfigFiles.read(:views, "ui")

      assert {:error, :unsafe_path} =
               ConfigFiles.save(:views, "ui", String.replace(@views, "Mine", "Ours"), hash,
                 author: @ada
               )

      assert File.read!(target) == @views
    end
  end

  describe "a directory that refuses writes" do
    @describetag skip: root_user?() && "root writes through file permissions"

    setup ctx do
      on_exit(fn -> File.chmod!(ctx.root, 0o755) end)
      :ok
    end

    test "shows the live file as the applied document and refuses every write", ctx do
      File.chmod!(ctx.root, 0o555)
      read_only = {:error, {:read_only, ctx.root}}

      assert %{applied: "omashiki", read_only: root, documents: [doc]} = ConfigFiles.list(:config)
      assert root == ctx.root
      assert %{name: "omashiki", applied?: true, path: path} = doc
      assert path == ctx.path

      assert {:ok, %{content: content, hash: hash}} = ConfigFiles.read(:config, "omashiki")
      assert content == house_toml()

      assert ConfigFiles.create(:config, "next", from: :blank, author: @ada) == read_only
      assert ConfigFiles.save(:config, "omashiki", "a = 1\n", hash, author: @ada) == read_only
      assert ConfigFiles.apply(:config, "omashiki", author: @ada) == read_only
      assert ConfigFiles.delete(:config, "omashiki", author: @ada) == read_only
      refute File.exists?(ctx.store)
      assert File.read!(ctx.path) == house_toml()
    end

    test "reads the live file after an outside edit it cannot adopt", ctx do
      ConfigFiles.list(:config)
      File.chmod!(Path.join(ctx.store, "config"), 0o555)
      on_exit(fn -> File.chmod!(Path.join(ctx.store, "config"), 0o755) end)
      edited = house_toml(model: "edited-outside")
      File.write!(ctx.path, edited)

      assert %{drift?: true, read_only: dir} = ConfigFiles.list(:config)
      assert dir == Path.join(ctx.store, "config")
      assert {:ok, %{content: ^edited}} = ConfigFiles.read(:config, "omashiki")
      assert ConfigFiles.history(:config, "omashiki") == []
    end
  end

  describe "views" do
    test "validate with the task views parser", _ctx do
      assert {:ok, %{}} = ConfigFiles.validate(:views, @views)
      assert {:error, message} = ConfigFiles.validate(:views, "")
      assert message =~ "declare at least one [[views]] table"

      assert {:error, message} = ConfigFiles.validate(:views, @views <> "not [ toml\n")
      assert ConfigFiles.error_lines(:views, "ui", message) == [4]
    end

    test "apply writes the file the screen reads", ctx do
      {:ok, doc} = ConfigFiles.create(:views, "mine", from: :blank, author: @ada)
      {:ok, _doc} = ConfigFiles.save(:views, "mine", @views, doc.hash, author: @ada)

      assert {:ok, %{document: %{applied?: true}, reload: nil}} =
               ConfigFiles.apply(:views, "mine", author: @ada)

      assert %TaskViews{source: :file, views: [%{name: "mine"}]} = TaskViews.load(ctx.views)
    end
  end

  defp sha(content), do: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)
end
