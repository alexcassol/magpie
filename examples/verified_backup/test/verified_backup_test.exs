defmodule VerifiedBackupTest do
  use ExUnit.Case, async: true
  alias VerifiedBackup.DropboxFixture
  @moduletag :tmp_dir

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "create drills before publishing and restore detects corruption", %{tmp_dir: dir} do
    VerifiedBackup.BackupScenario.run(dir)
  end

  test "unsafe paths, collisions and malformed manifests fail before I/O", %{tmp_dir: dir} do
    for path <- [
          "../secret",
          "/secret",
          "a/../secret",
          "a//b",
          "a\\b",
          "a:",
          "a/./b",
          "a/",
          " a",
          <<0>>
        ] do
      assert {:error, :invalid_manifest} =
               VerifiedBackup.restore(
                 DropboxFixture.client(),
                 manifest([entry(path)]),
                 Path.join(dir, "restore")
               )
    end

    for files <- [[entry("A"), entry("a")], [entry("a"), entry("a/b")]] do
      assert {:error, :invalid_manifest} = VerifiedBackup.validate(manifest(files))
    end

    for bad <- [
          nil,
          %{},
          %{manifest([]) | "created_at" => "yesterday"},
          manifest([%{entry("a") | "rev" => "bad"}])
        ] do
      assert {:error, :invalid_manifest} = VerifiedBackup.validate(bad)
    end
  end

  test "existing destinations, including dangling symlinks, are untouched", %{tmp_dir: dir} do
    destination = Path.join(dir, "restore")
    File.mkdir!(destination)
    File.write!(Path.join(destination, "keep"), "original")

    assert {:error, :destination_exists} =
             VerifiedBackup.restore(DropboxFixture.client(), manifest([]), destination)

    assert File.read!(Path.join(destination, "keep")) == "original"
    link = Path.join(dir, "link")
    File.ln_s!(Path.join(dir, "missing"), link)

    assert {:error, :destination_exists} =
             VerifiedBackup.restore(DropboxFixture.client(), manifest([]), link)
  end

  test "symlinks in a source fail before uploading", %{tmp_dir: dir} do
    File.ln_s!("/etc/hosts", Path.join(dir, "link"))

    assert {:error, {:unsupported_file, "link"}} =
             VerifiedBackup.create(DropboxFixture.client(), dir)
  end

  test "failed drill never uploads a manifest", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "data"), "original")
    DropboxFixture.rpc("get_metadata", %{}, DropboxFixture.folder("/MagpieBackups"))

    DropboxFixture.rpc("create_folder_v2", %{}, %{
      "metadata" => DropboxFixture.folder("/MagpieBackups/snapshot")
    })

    DropboxFixture.upload(fn _, _ -> :ok end, "00000000001")
    DropboxFixture.download("rev:00000000001", "corrupt")

    assert {:error, {:integrity_mismatch, "data"}} =
             VerifiedBackup.create(DropboxFixture.client(), dir)
  end

  test "failed upload stops before the drill or manifest", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "data"), "original")
    DropboxFixture.rpc("get_metadata", %{}, DropboxFixture.folder("/MagpieBackups"))

    DropboxFixture.rpc("create_folder_v2", %{}, %{
      "metadata" => DropboxFixture.folder("/MagpieBackups/snapshot")
    })

    Req.Test.expect(DropboxFixture, fn conn ->
      assert conn.request_path == "/2/files/upload"
      conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error_summary" => "unavailable"})
    end)

    assert {:error, %Magpie.Error{status: 503}} =
             VerifiedBackup.create(DropboxFixture.client(), dir)
  end

  test "partial restore is removed when a later file fails verification", %{tmp_dir: dir} do
    destination = Path.join(dir, "restore")
    DropboxFixture.download("rev:00000000001", "contents")
    DropboxFixture.download("rev:00000000001", "corrupt!")

    assert {:error, {:integrity_mismatch, "second"}} =
             VerifiedBackup.restore(
               DropboxFixture.client(),
               manifest([entry("first"), entry("second")]),
               destination
             )

    refute File.exists?(destination)
    assert Path.wildcard(destination <> ".restoring-*") == []
  end

  test "retention sorts completed snapshots and leaves incomplete ones out" do
    root = "/MagpieBackups"
    folders = Enum.map(["older", "newer", "partial"], &DropboxFixture.folder(root <> "/" <> &1))

    DropboxFixture.rpc("list_folder", %{"path" => root}, %{
      "entries" => folders,
      "cursor" => "done",
      "has_more" => false
    })

    DropboxFixture.download(
      root <> "/older/manifest.json",
      Jason.encode!(%{manifest([]) | "created_at" => "2026-01-01T00:00:00Z"})
    )

    DropboxFixture.download(
      root <> "/newer/manifest.json",
      Jason.encode!(%{manifest([]) | "created_at" => "2026-02-01T00:00:00Z"})
    )

    Req.Test.expect(DropboxFixture, fn conn ->
      assert DropboxFixture.arg(conn)["path"] == root <> "/partial/manifest.json"

      conn
      |> Plug.Conn.put_status(409)
      |> Req.Test.json(%{
        "error_summary" => "path/not_found/",
        "error" => %{".tag" => "path", "path" => %{".tag" => "not_found"}}
      })
    end)

    assert {:ok,
            %{
              keep: ["/MagpieBackups/newer"],
              delete_candidates: ["/MagpieBackups/older"],
              incomplete: ["/MagpieBackups/partial"]
            }} = VerifiedBackup.retention(DropboxFixture.client(), root, 1)
  end

  defp entry(path),
    do: %{
      "path" => path,
      "rev" => "00000000001",
      "size" => 8,
      "content_hash" => Magpie.Metadata.content_hash("contents")
    }

  defp manifest(files),
    do: %{
      "version" => 1,
      "id" => "snapshot",
      "created_at" => "2026-01-01T00:00:00Z",
      "files" => files
    }
end
