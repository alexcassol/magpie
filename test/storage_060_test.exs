defmodule Magpie.Storage060Test do
  use ExUnit.Case, async: true

  alias Magpie.BatchError
  alias Magpie.Client
  alias Magpie.Error
  alias Magpie.FileMetadata
  alias Magpie.FolderMetadata
  alias Magpie.IntegrityError
  alias Magpie.Metadata
  alias Magpie.Storage

  @client Client.new("fake-token")

  describe "integrity and conditional writes" do
    @tag :tmp_dir
    test "verifies a local file upload", %{tmp_dir: dir} do
      path = Path.join(dir, "verified.txt")
      File.write!(path, "from-file")
      hash = Metadata.content_hash("from-file")

      Req.Test.stub(Magpie, fn conn ->
        Req.Test.json(conn, %{
          ".tag" => "file",
          "name" => "verified.txt",
          "content_hash" => hash
        })
      end)

      assert {:ok, %FileMetadata{content_hash: ^hash}} =
               Storage.put(@client, "/verified.txt", {:file, path}, verify: true)
    end

    test "verifies a binary upload against Dropbox's content hash" do
      hash = Metadata.content_hash("verified")

      Req.Test.stub(Magpie, fn conn ->
        Req.Test.json(conn, %{
          ".tag" => "file",
          "name" => "verified.txt",
          "rev" => "1",
          "size" => 8,
          "content_hash" => hash
        })
      end)

      assert {:ok, %FileMetadata{content_hash: ^hash}} =
               Storage.put(@client, "/verified.txt", {:binary, "verified"}, verify: true)
    end

    test "returns a dedicated integrity error and the bang variant raises it" do
      Req.Test.stub(Magpie, fn conn ->
        Req.Test.json(conn, %{
          ".tag" => "file",
          "name" => "bad.txt",
          "content_hash" => String.duplicate("0", 64)
        })
      end)

      assert {:error, %IntegrityError{path: "/bad.txt"} = error} =
               Storage.put(@client, "/bad.txt", {:binary, "actual"}, verify: true)

      assert Error.integrity?(error)

      assert_raise IntegrityError, fn ->
        Storage.put!(@client, "/bad.txt", {:binary, "actual"}, verify: true)
      end
    end

    test "skips an unchanged source without calling upload" do
      hash = Metadata.content_hash("same")

      Req.Test.stub(Magpie, fn conn ->
        assert conn.request_path == "/2/files/get_metadata"

        Req.Test.json(conn, %{
          ".tag" => "file",
          "name" => "same.txt",
          "rev" => "old",
          "content_hash" => hash
        })
      end)

      assert {:ok, :unchanged, %FileMetadata{rev: "old"}} =
               Storage.put(@client, "/same.txt", {:binary, "same"}, skip_unchanged: true)

      assert {:unchanged, %FileMetadata{rev: "old"}} =
               Storage.put!(@client, "/same.txt", {:binary, "same"}, skip_unchanged: true)
    end

    test "uploads changed content and treats a missing remote path as changed" do
      test_pid = self()

      Req.Test.stub(Magpie, fn conn ->
        case conn.request_path do
          "/2/files/get_metadata" ->
            if conn.body_params["path"] == "/changed.txt" do
              Req.Test.json(conn, %{
                ".tag" => "file",
                "name" => "changed.txt",
                "content_hash" => Metadata.content_hash("old")
              })
            else
              conn
              |> Plug.Conn.put_status(409)
              |> Req.Test.json(%{"error_summary" => "path/not_found/.."})
            end

          "/2/files/upload" ->
            send(test_pid, {:uploaded, Req.Test.raw_body(conn)})
            Req.Test.json(conn, %{".tag" => "file", "name" => "uploaded.txt"})
        end
      end)

      assert {:ok, %FileMetadata{}} =
               Storage.put(@client, "/changed.txt", {:binary, "new"}, skip_unchanged: true)

      assert {:ok, %FileMetadata{}} =
               Storage.put(@client, "/missing.txt", {:binary, "new"}, skip_unchanged: true)

      assert_received {:uploaded, "new"}
      assert_received {:uploaded, "new"}
    end

    test "does not upload when unchanged detection itself fails" do
      Req.Test.stub(Magpie, fn conn ->
        assert conn.request_path == "/2/files/get_metadata"

        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error_summary" => "access_error/.."})
      end)

      assert {:error, %Error{status: 403}} =
               Storage.put(@client, "/blocked", {:binary, "data"}, skip_unchanged: true)
    end

    test "verifies a stream while uploading it once" do
      hash = Metadata.content_hash("abcdef")

      Req.Test.stub(Magpie, fn conn ->
        case conn.request_path do
          "/2/files/upload_session/start" ->
            Req.Test.json(conn, %{"session_id" => "verify-stream"})

          "/2/files/upload_session/append_v2" ->
            Plug.Conn.send_resp(conn, 200, "")

          "/2/files/upload_session/finish" ->
            Req.Test.json(conn, %{
              ".tag" => "file",
              "name" => "stream.txt",
              "content_hash" => hash
            })
        end
      end)

      assert {:ok, %FileMetadata{content_hash: ^hash}} =
               Storage.put(@client, "/stream.txt", {:stream, ["ab", "cd", "ef"]},
                 verify: true,
                 chunk_size: 2
               )

      assert_raise ArgumentError, ~r/skip_unchanged/, fn ->
        Storage.put(@client, "/stream.txt", {:stream, ["x"]}, skip_unchanged: true)
      end
    end

    test "encodes if_rev as Dropbox's update write mode" do
      Req.Test.stub(Magpie, fn conn ->
        case conn.request_path do
          "/2/files/upload" ->
            arg = conn |> Plug.Conn.get_req_header("dropbox-api-arg") |> hd() |> Jason.decode!()
            assert arg["mode"] == %{".tag" => "update", "update" => "rev-42"}
            Req.Test.json(conn, %{".tag" => "file", "name" => "a.txt"})

          "/2/files/get_temporary_upload_link" ->
            assert conn.body_params["commit_info"]["mode"] == %{
                     ".tag" => "update",
                     "update" => "rev-42"
                   }

            Req.Test.json(conn, %{"link" => "https://up"})
        end
      end)

      assert {:ok, %FileMetadata{}} =
               Storage.put(@client, "/a.txt", {:binary, "a"}, if_rev: "rev-42")

      assert {:ok, "https://up"} = Storage.upload_url(@client, "/a.txt", if_rev: "rev-42")

      assert_raise ArgumentError, ~r/:if_rev/, fn ->
        Storage.put(@client, "/a.txt", {:binary, "a"}, if_rev: 42)
      end

      assert_raise ArgumentError, ~r/:if_rev/, fn ->
        Storage.upload_url(@client, "/a.txt", if_rev: 42)
      end
    end
  end

  describe "operations and transport normalization" do
    test "copy, move and mkdir return typed metadata with bang variants" do
      Req.Test.stub(Magpie, fn conn ->
        case conn.request_path do
          "/2/files/copy_v2" ->
            Req.Test.json(conn, %{
              "metadata" => %{".tag" => "file", "name" => "copy.txt", "rev" => "1"}
            })

          "/2/files/move_v2" ->
            Req.Test.json(conn, %{
              "metadata" => %{".tag" => "file", "name" => "moved.txt", "rev" => "2"}
            })

          "/2/files/create_folder_v2" ->
            Req.Test.json(conn, %{
              "metadata" => %{".tag" => "folder", "name" => "New", "id" => "id:new"}
            })
        end
      end)

      assert {:ok, %FileMetadata{name: "copy.txt"}} = Storage.copy(@client, "/a", "/copy")
      assert %FileMetadata{name: "copy.txt"} = Storage.copy!(@client, "/a", "/copy")
      assert {:ok, %FileMetadata{name: "moved.txt"}} = Storage.move(@client, "/a", "/moved")
      assert %FileMetadata{name: "moved.txt"} = Storage.move!(@client, "/a", "/moved")
      assert {:ok, %FolderMetadata{name: "New"}} = Storage.mkdir(@client, "/New")
      assert %FolderMetadata{name: "New"} = Storage.mkdir!(@client, "/New")
    end

    @tag :tmp_dir
    test "normal operations return transport failures instead of raising", %{tmp_dir: dir} do
      Req.Test.stub(Magpie, &Req.Test.transport_error(&1, :timeout))
      destination = Path.join(dir, "download.bin")

      operations = [
        fn -> Storage.put(@client, "/a", {:binary, "a"}) end,
        fn -> Storage.get(@client, "/a") end,
        fn -> Storage.download(@client, "/a", destination) end,
        fn -> Storage.delete(@client, "/a") end,
        fn -> Storage.stat(@client, "/a") end,
        fn -> Storage.exists?(@client, "/a") end,
        fn -> Storage.url(@client, "/a") end,
        fn -> Storage.upload_url(@client, "/a") end,
        fn -> Storage.copy(@client, "/a", "/b") end,
        fn -> Storage.move(@client, "/a", "/b") end,
        fn -> Storage.mkdir(@client, "/a") end
      ]

      for operation <- operations do
        assert {:error, %Req.TransportError{reason: :timeout}} = operation.()
      end
    end

    test "Dropbox request IDs are kept on normalized errors" do
      Req.Test.stub(Magpie, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-dropbox-request-id", "req-123")
        |> Plug.Conn.put_status(409)
        |> Req.Test.json(%{"error_summary" => "path/not_found/.."})
      end)

      assert {:error, %Error{request_id: "req-123"}} = Storage.stat(@client, "/missing")
    end
  end

  describe "progress and batches" do
    @tag :tmp_dir
    test "reports upload and streaming download progress", %{tmp_dir: dir} do
      test_pid = self()

      Req.Test.stub(Magpie, fn conn ->
        case conn.request_path do
          "/2/files/upload" ->
            Req.Test.json(conn, %{".tag" => "file", "name" => "a.txt"})

          "/2/files/download" ->
            conn = Plug.Conn.send_chunked(conn, 200)
            {:ok, conn} = Plug.Conn.chunk(conn, "abc")
            {:ok, conn} = Plug.Conn.chunk(conn, "def")
            conn
        end
      end)

      assert {:ok, %FileMetadata{}} =
               Storage.put(@client, "/a.txt", {:binary, "abc"},
                 progress: fn sent, total -> send(test_pid, {:upload, sent, total}) end
               )

      assert_received {:upload, 3, 3}

      destination = Path.join(dir, "a.txt")

      assert {:ok, ^destination} =
               Storage.download(@client, "/a.txt", destination,
                 size: 6,
                 progress: fn received, total -> send(test_pid, {:download, received, total}) end
               )

      assert_received {:download, 6, 6}
      assert File.read!(destination) == "abcdef"
    end

    test "put_many preserves order, merges item options and isolates an invalid item" do
      test_pid = self()

      Req.Test.stub(Magpie, fn conn ->
        arg = conn |> Plug.Conn.get_req_header("dropbox-api-arg") |> hd() |> Jason.decode!()
        send(test_pid, {:mode, arg["path"], arg["mode"]})
        Req.Test.json(conn, %{".tag" => "file", "name" => Path.basename(arg["path"])})
      end)

      entries = [
        {"/one", {:binary, "1"}},
        {"/bad", {:unknown, "x"}},
        {"/three", {:binary, "3"}, mode: "add"}
      ]

      assert {:ok,
              [
                {"/one", {:ok, %FileMetadata{name: "one"}}},
                {"/bad", {:error, %ArgumentError{}}},
                {"/three", {:ok, %FileMetadata{name: "three"}}}
              ]} =
               Storage.put_many(@client, entries,
                 mode: "overwrite",
                 max_concurrency: 2,
                 on_progress: fn key, result -> send(test_pid, {:done, key, result}) end
               )

      assert_received {:mode, "/one", "overwrite"}
      assert_received {:mode, "/three", "add"}
      assert_received {:done, "/bad", {:error, %ArgumentError{}}}
    end

    test "delete_many keeps per-item Dropbox errors" do
      Req.Test.stub(Magpie, fn conn ->
        if conn.body_params["path"] == "/missing" do
          conn
          |> Plug.Conn.put_status(409)
          |> Req.Test.json(%{"error_summary" => "path/not_found/.."})
        else
          Req.Test.json(conn, %{
            "metadata" => %{".tag" => "file", "name" => "ok", "rev" => "1"}
          })
        end
      end)

      assert {:ok,
              [
                {"/ok", {:ok, %FileMetadata{name: "ok"}}},
                {"/missing", {:error, %Error{status: 409}}}
              ]} = Storage.delete_many(@client, ["/ok", "/missing"], max_concurrency: 2)
    end

    test "batch timeouts become item errors" do
      Req.Test.stub(Magpie, fn conn ->
        Process.sleep(50)
        Req.Test.json(conn, %{".tag" => "file", "name" => "slow"})
      end)

      assert {:ok, [{"/slow", {:error, %BatchError{operation: :put}}}]} =
               Storage.put_many(@client, [{"/slow", {:binary, "x"}}], timeout: 1)
    end

    test "batch workers isolate thrown stream failures" do
      Req.Test.stub(Magpie, fn conn ->
        assert conn.request_path == "/2/files/upload_session/start"
        Req.Test.json(conn, %{"session_id" => "throwing-stream"})
      end)

      source = Stream.map(["x"], fn _ -> throw(:broken_source) end)

      assert {:ok, [{"/throw", {:error, %BatchError{operation: :worker} = error}}]} =
               Storage.put_many(@client, [{"/throw", {:stream, source}}])

      assert Exception.message(error) =~ "broken_source"
    end

    test "validates batch callbacks and entry shapes" do
      assert_raise ArgumentError, ~r/on_progress/, fn ->
        Storage.delete_many(@client, [], on_progress: :invalid)
      end

      assert {:ok, [{:invalid, {:error, %ArgumentError{}}}]} =
               Storage.put_many(@client, [:invalid])

      assert {:ok, []} = Storage.delete_many(@client, [])

      assert_raise ArgumentError, ~r/:progress/, fn ->
        Storage.put(@client, "/a", {:binary, "a"}, progress: :invalid)
      end
    end
  end
end
