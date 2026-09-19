defmodule Magpie.DropboxIntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :dropbox
  @moduletag timeout: 120_000

  alias Magpie.{Client, FileMetadata, Storage}

  setup do
    # Use a test account: this test creates and deletes files.
    token = System.fetch_env!("MAGPIE_TEST_DROPBOX_TOKEN")
    client = Client.new(token, req_options: [plug: nil], retry: false, timeout: 30_000)
    id = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    root = "/magpie-integration-#{id}"
    assert {:ok, _} = Storage.mkdir(client, root)
    on_exit(fn -> assert {:ok, _} = Storage.delete(client, root) end)
    %{client: client, root: root}
  end

  @tag :tmp_dir
  test "storage contract against a dedicated Dropbox account", %{
    client: client,
    root: root,
    tmp_dir: dir
  } do
    path = root <> "/sample.txt"

    assert {:ok, %FileMetadata{rev: rev}} =
             Storage.put(client, path, {:binary, "first"},
               mode: "overwrite",
               autorename: false,
               verify: true
             )

    assert {:ok, "first"} = Storage.get(client, path)

    assert {:ok, %FileMetadata{}} =
             Storage.put(client, path, {:binary, "second"}, if_rev: rev, verify: true)

    assert {:error, error} = Storage.put(client, path, {:binary, "stale"}, if_rev: rev)
    assert Magpie.Error.conflict?(error)
    # A one-entry page makes the listing use a continuation cursor.
    assert {:ok, _} = Storage.put(client, root <> "/other.txt", {:binary, "other"})
    assert {:ok, entries} = Storage.list(client, root, limit: 1)
    assert Enum.sort(Enum.map(entries, & &1.name)) == ["other.txt", "sample.txt"]
    destination = Path.join(dir, "download.txt")
    assert {:ok, ^destination} = Storage.download(client, path, destination)
    assert File.read!(destination) == "second"
  end
end
