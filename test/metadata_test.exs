defmodule Magpie.MetadataTest do
  @moduledoc """
  Tests for the typed metadata: decoding the three kinds of entry, the
  response shapes the `files` endpoints wrap them in, and the content hash.
  """
  use ExUnit.Case, async: true

  doctest Magpie.Metadata

  alias Magpie.DeletedMetadata
  alias Magpie.FileMetadata
  alias Magpie.FolderMetadata
  alias Magpie.Metadata

  @client Magpie.Client.new("fake-token")

  @file_entry %{
    ".tag" => "file",
    "name" => "report.pdf",
    "id" => "id:a4ayc_80_OEAAAAAAAAAXw",
    "path_lower" => "/backup/report.pdf",
    "path_display" => "/Backup/report.pdf",
    "client_modified" => "2026-09-01T15:50:38Z",
    "server_modified" => "2026-09-01T15:50:39Z",
    "rev" => "015d5ff0b3f0e4a000000027c3f9a10",
    "size" => 48_213,
    "content_hash" => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "is_downloadable" => false,
    "has_explicit_shared_members" => false,
    "sharing_info" => %{"read_only" => true, "parent_shared_folder_id" => "84528192421"},
    "file_lock_info" => %{"is_lockholder" => true, "lockholder_name" => "Imaginary User"},
    "property_groups" => [%{"template_id" => "ptid:1a5n2i6d3OYEAAAAAAAAAYa", "fields" => []}]
  }

  @folder_entry %{
    ".tag" => "folder",
    "name" => "Photos",
    "id" => "id:folder",
    "path_lower" => "/photos",
    "path_display" => "/Photos",
    "shared_folder_id" => "84528192421",
    "sharing_info" => %{"read_only" => false, "shared_folder_id" => "84528192421"}
  }

  @deleted_entry %{
    ".tag" => "deleted",
    "name" => "old.txt",
    "path_lower" => "/old.txt",
    "path_display" => "/old.txt",
    "is_restorable" => true
  }

  describe "decode/2" do
    test "decodes a tagged file with typed timestamps and a first-class content_hash" do
      assert %FileMetadata{
               name: "report.pdf",
               id: "id:a4ayc_80_OEAAAAAAAAAXw",
               path_display: "/Backup/report.pdf",
               client_modified: ~U[2026-09-01 15:50:38Z],
               server_modified: ~U[2026-09-01 15:50:39Z],
               rev: "015d5ff0b3f0e4a000000027c3f9a10",
               size: 48_213,
               content_hash: "e3b0c442" <> _,
               is_downloadable: false,
               has_explicit_shared_members: false,
               sharing_info: %{"read_only" => true},
               file_lock_info: %{"is_lockholder" => true},
               property_groups: [%{"template_id" => "ptid:" <> _}]
             } = Metadata.decode(@file_entry)
    end

    test "is_downloadable defaults to true when Dropbox omits it" do
      assert %FileMetadata{is_downloadable: true} =
               Metadata.decode(Map.delete(@file_entry, "is_downloadable"))
    end

    test "decodes a tagged folder" do
      assert %FolderMetadata{
               name: "Photos",
               id: "id:folder",
               path_lower: "/photos",
               shared_folder_id: "84528192421",
               sharing_info: %{"read_only" => false}
             } = Metadata.decode(@folder_entry)
    end

    test "decodes a tagged deleted entry, including is_restorable" do
      assert %DeletedMetadata{name: "old.txt", path_lower: "/old.txt", is_restorable: true} =
               Metadata.decode(@deleted_entry)

      assert %DeletedMetadata{is_restorable: nil} =
               Metadata.decode(Map.delete(@deleted_entry, "is_restorable"))
    end

    test "infers untagged entries: files have a rev, folders do not" do
      assert %FileMetadata{name: "a.txt"} = Metadata.decode(%{"name" => "a.txt", "rev" => "1"})
      assert %FolderMetadata{name: "Photos"} = Metadata.decode(%{"name" => "Photos"})
    end

    test "an explicit kind decides untagged entries, but never overrides a tag" do
      assert %FileMetadata{name: "x"} = Metadata.decode(%{"name" => "x"}, :file)
      assert %FolderMetadata{name: "x"} = Metadata.decode(%{"name" => "x", "rev" => "1"}, :folder)
      assert %DeletedMetadata{name: "old.txt"} = Metadata.decode(@deleted_entry, :file)
      assert %FolderMetadata{name: "Photos"} = Metadata.decode(@folder_entry, :file)
    end

    test "leaves unknown tags and non-map values alone" do
      unknown = %{".tag" => "hologram", "name" => "x"}
      assert Metadata.decode(unknown) == unknown
      assert Metadata.decode(%{"ok" => true}) == %{"ok" => true}
      assert Metadata.decode(nil) == nil
      assert Metadata.decode("bytes") == "bytes"
      assert Metadata.decode([@file_entry]) == [@file_entry]
    end

    test "keeps a timestamp Dropbox formats unexpectedly instead of crashing" do
      assert %FileMetadata{client_modified: "yesterday"} =
               Metadata.decode(%{@file_entry | "client_modified" => "yesterday"})

      assert %FileMetadata{client_modified: nil} =
               Metadata.decode(Map.delete(@file_entry, "client_modified"))
    end
  end

  describe "unwrap/2" do
    test "returns the struct under \"metadata\"" do
      assert %FileMetadata{name: "report.pdf"} = Metadata.unwrap(%{"metadata" => @file_entry})

      assert %FolderMetadata{name: "x"} =
               Metadata.unwrap(%{"metadata" => %{"name" => "x"}}, :folder)
    end

    test "passes other shapes through" do
      assert Metadata.unwrap(%{"ok" => true}) == %{"ok" => true}
      assert Metadata.unwrap(nil) == nil
    end
  end

  describe "decode_page/2" do
    test "decodes the entries and keeps the rest of the page" do
      page = %{
        "entries" => [@file_entry, @folder_entry, @deleted_entry],
        "cursor" => "c1",
        "has_more" => true
      }

      assert %{
               "entries" => [%FileMetadata{}, %FolderMetadata{}, %DeletedMetadata{}],
               "cursor" => "c1",
               "has_more" => true
             } = Metadata.decode_page(page)
    end

    test "applies the kind to untagged entries" do
      assert %{"entries" => [%FileMetadata{name: "a"}]} =
               Metadata.decode_page(%{"entries" => [%{"name" => "a"}]}, :file)
    end

    test "passes pages without a list of entries through" do
      assert Metadata.decode_page(%{"ok" => true}) == %{"ok" => true}
      assert Metadata.decode_page(%{"entries" => nil}) == %{"entries" => nil}
      assert Metadata.decode_page("nope") == "nope"
    end
  end

  describe "decode_matches/1" do
    test "flattens the metadata union of every match" do
      match = %{
        "match_type" => %{".tag" => "filename"},
        "metadata" => %{".tag" => "metadata", "metadata" => @file_entry},
        "highlights" => []
      }

      assert %{"matches" => [decoded], "has_more" => false} =
               Metadata.decode_matches(%{"matches" => [match], "has_more" => false})

      assert %{"match_type" => %{".tag" => "filename"}, "highlights" => []} = decoded
      assert %FileMetadata{name: "report.pdf"} = decoded["metadata"]
    end

    test "leaves matches of another union variant and other shapes alone" do
      other = %{"metadata" => %{".tag" => "other", "x" => 1}}
      assert Metadata.decode_matches(%{"matches" => [other]}) == %{"matches" => [other]}
      assert Metadata.decode_matches(%{"ok" => true}) == %{"ok" => true}
    end
  end

  describe "content_hash/1" do
    @block 4 * 1024 * 1024

    defp reference_hash(binary) do
      binary
      |> chunk_every(@block)
      |> Enum.map(&:crypto.hash(:sha256, &1))
      |> IO.iodata_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end

    defp chunk_every(<<>>, _size), do: []

    defp chunk_every(binary, size) when byte_size(binary) <= size, do: [binary]

    defp chunk_every(binary, size) do
      <<head::binary-size(^size), rest::binary>> = binary
      [head | chunk_every(rest, size)]
    end

    test "the empty file hashes to the SHA-256 of nothing, as Dropbox documents" do
      assert Metadata.content_hash("") ==
               "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    end

    test "a file under one block is the hash of its single block hash" do
      assert Metadata.content_hash("hello dropbox") == reference_hash("hello dropbox")
    end

    test "content spanning several blocks is hashed block by block" do
      data = :crypto.strong_rand_bytes(2 * @block + 12_345)
      assert Metadata.content_hash(data) == reference_hash(data)

      # exactly on a block boundary: no dangling partial block
      exact = :crypto.strong_rand_bytes(@block)
      assert Metadata.content_hash(exact) == reference_hash(exact)
    end

    test "chunk boundaries of a stream do not affect the result" do
      data = :crypto.strong_rand_bytes(@block + 100)
      chunks = chunk_every(data, 1_000_003)

      assert Metadata.content_hash(chunks) == Metadata.content_hash(data)
      assert Metadata.content_hash(Stream.map(chunks, & &1)) == Metadata.content_hash(data)
    end

    @tag :tmp_dir
    test "works with File.stream!/2", %{tmp_dir: dir} do
      path = Path.join(dir, "blob.bin")
      data = :crypto.strong_rand_bytes(300_000)
      File.write!(path, data)

      assert Metadata.content_hash(File.stream!(path, 65_536)) == reference_hash(data)
    end
  end

  describe "through the files endpoints" do
    test "get_metadata/2 returns the struct matching the tag" do
      Req.Test.stub(Magpie, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        case Jason.decode!(raw) do
          %{"path" => "/Backup/report.pdf"} -> Req.Test.json(conn, @file_entry)
          %{"path" => "/Photos"} -> Req.Test.json(conn, @folder_entry)
          %{"path" => "/old.txt"} -> Req.Test.json(conn, @deleted_entry)
        end
      end)

      assert {:ok, %FileMetadata{size: 48_213, server_modified: %DateTime{}}} =
               Magpie.Files.get_metadata(@client, "/Backup/report.pdf")

      assert {:ok, %FolderMetadata{name: "Photos"}} =
               Magpie.Files.get_metadata(@client, "/Photos")

      assert {:ok, %DeletedMetadata{name: "old.txt"}} =
               Magpie.Files.get_metadata(@client, "/old.txt", false, true)
    end

    test "errors are untouched by the decoding" do
      Req.Test.stub(Magpie, fn conn ->
        conn
        |> Plug.Conn.put_status(409)
        |> Req.Test.json(%{"error_summary" => "path/not_found/"})
      end)

      assert {:error, %Magpie.Error{status: 409, summary: "path/not_found/"}} =
               Magpie.Files.get_metadata(@client, "/missing")

      assert {:error, %Magpie.Error{status: 409}} = Magpie.Files.create_folder(@client, "/x")

      assert {:error, %Magpie.Error{status: 409}} =
               Magpie.Files.ListFolder.list_folder(@client, "")
    end

    test "delete_folder/2, copy/3 and move/3 unwrap the relocation result" do
      Req.Test.stub(Magpie, fn conn ->
        case conn.request_path do
          "/2/files/delete_v2" -> Req.Test.json(conn, %{"metadata" => @file_entry})
          "/2/files/copy_v2" -> Req.Test.json(conn, %{"metadata" => @folder_entry})
          "/2/files/move_v2" -> Req.Test.json(conn, %{"metadata" => @file_entry})
        end
      end)

      assert {:ok, %FileMetadata{name: "report.pdf"}} =
               Magpie.Files.delete_folder(@client, "/Backup/report.pdf")

      assert {:ok, %FolderMetadata{name: "Photos"}} = Magpie.Files.copy(@client, "/Photos", "/P2")
      assert {:ok, %FileMetadata{}} = Magpie.Files.move(@client, "/Backup/report.pdf", "/r.pdf")
    end

    test "restore/3 and list_revisions/4 decode Dropbox's untagged file metadata" do
      untagged = Map.delete(@file_entry, ".tag")

      Req.Test.stub(Magpie, fn conn ->
        case conn.request_path do
          "/2/files/restore" ->
            Req.Test.json(conn, untagged)

          "/2/files/list_revisions" ->
            Req.Test.json(conn, %{"entries" => [untagged], "is_deleted" => false})
        end
      end)

      assert {:ok, %FileMetadata{rev: "015d5ff0b3f0e4a000000027c3f9a10"}} =
               Magpie.Files.restore(@client, "/Backup/report.pdf", "015")

      assert {:ok, %{"entries" => [%FileMetadata{}], "is_deleted" => false}} =
               Magpie.Files.ListFolder.list_revisions(@client, "/Backup/report.pdf")
    end

    test "search/3 and search_continue/2 decode each match's metadata" do
      Req.Test.stub(Magpie, fn conn ->
        match = %{
          "match_type" => %{".tag" => "filename"},
          "metadata" => %{".tag" => "metadata", "metadata" => @folder_entry}
        }

        Req.Test.json(conn, %{"matches" => [match], "has_more" => false})
      end)

      assert {:ok, %{"matches" => [%{"metadata" => %FolderMetadata{name: "Photos"}}]}} =
               Magpie.Files.search(@client, "Photos")

      assert {:ok, %{"matches" => [%{"metadata" => %FolderMetadata{}}]}} =
               Magpie.Files.search_continue(@client, "cursor")
    end

    test "ListFolder.stream/3 yields structs of all three kinds across pages" do
      Req.Test.stub(Magpie, fn conn ->
        case conn.request_path do
          "/2/files/list_folder" ->
            Req.Test.json(conn, %{
              "entries" => [@folder_entry, @file_entry],
              "cursor" => "c",
              "has_more" => true
            })

          "/2/files/list_folder/continue" ->
            Req.Test.json(conn, %{
              "entries" => [@deleted_entry],
              "cursor" => "d",
              "has_more" => false
            })
        end
      end)

      assert [%FolderMetadata{}, %FileMetadata{}, %DeletedMetadata{}] =
               @client
               |> Magpie.Files.ListFolder.stream("", %{"include_deleted" => true})
               |> Enum.to_list()
    end

    test "upload_session finish_data/5 hands back the committed file" do
      Req.Test.stub(Magpie, fn conn ->
        assert conn.request_path == "/2/files/upload_session/finish"
        Req.Test.json(conn, Map.delete(@file_entry, ".tag"))
      end)

      assert {:ok, %FileMetadata{content_hash: "e3b0c442" <> _}} =
               Magpie.Files.UploadSession.finish_data(@client, "s1", 0, %{"path" => "/r.pdf"})
    end

    test "the raw payload stays reachable through Magpie.post/3" do
      Req.Test.stub(Magpie, fn conn -> Req.Test.json(conn, @file_entry) end)

      assert {:ok, %{".tag" => "file", "server_modified" => "2026-09-01T15:50:39Z"} = raw} =
               Magpie.post(@client, "/files/get_metadata", %{"path" => "/Backup/report.pdf"})

      assert %FileMetadata{server_modified: ~U[2026-09-01 15:50:39Z]} = Metadata.decode(raw)
    end
  end
end
