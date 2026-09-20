defmodule VerifiedBackup.BackupScenario do
  import ExUnit.Assertions
  alias VerifiedBackup.DropboxFixture

  def run(directory, output \\ fn _ -> :ok end) do
    client = DropboxFixture.client()
    source = Path.join(directory, "source")
    File.mkdir_p!(Path.join(source, "reports"))
    body = "order_id,total_cents\nORDER-1001,24000\n"
    File.write!(Path.join(source, "reports/orders.csv"), body)
    owner = self()

    DropboxFixture.rpc(
      "get_metadata",
      %{"path" => "/MagpieBackups"},
      DropboxFixture.folder("/MagpieBackups")
    )

    Req.Test.expect(DropboxFixture, fn conn ->
      assert conn.request_path == "/2/files/create_folder_v2"
      args = conn |> Req.Test.raw_body() |> Jason.decode!()
      refute Map.get(args, "autorename", false)
      send(owner, {:snapshot_directory, args["path"]})
      Req.Test.json(conn, %{"metadata" => DropboxFixture.folder(args["path"])})
    end)

    DropboxFixture.upload(
      fn args, uploaded ->
        assert uploaded == body
        assert args["mode"] == "add"
        assert args["autorename"] == false
        assert String.ends_with?(args["path"], ".blob")
      end,
      "00000000001"
    )

    DropboxFixture.download("rev:00000000001", body)

    DropboxFixture.upload(fn args, uploaded ->
      assert String.ends_with?(args["path"], "/manifest.json")
      manifest = Jason.decode!(uploaded)
      assert [%{"path" => "reports/orders.csv"}] = manifest["files"]
      send(owner, {:manifest, manifest})
    end)

    assert {:ok, manifest_path} = VerifiedBackup.create(client, source)
    assert_received {:snapshot_directory, remote}
    assert manifest_path == remote <> "/manifest.json"
    assert_received {:manifest, manifest}
    output.("Snapshot uploaded. Restore drill passed. Manifest published last.")

    destination = Path.join(directory, "restored")
    DropboxFixture.download(manifest_path, Jason.encode!(manifest))
    DropboxFixture.download("rev:00000000001", body)
    assert {:ok, ^destination} = VerifiedBackup.restore_from(client, manifest_path, destination)
    assert File.read!(Path.join(destination, "reports/orders.csv")) == body
    output.("Restored reports/orders.csv from its recorded revision.")

    corrupt = Path.join(directory, "corrupt-restore")
    DropboxFixture.download("rev:00000000001", "damaged contents")

    assert {:error, {:integrity_mismatch, "reports/orders.csv"}} =
             VerifiedBackup.restore(client, manifest, corrupt)

    refute File.exists?(corrupt)
    DropboxFixture.verify!()
    output.("Corrupt download rejected. No restore directory was published.")
  end
end
