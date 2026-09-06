defmodule Magpie.StorageTest do
  use ExUnit.Case, async: true

  alias Magpie.Client
  alias Magpie.Error
  alias Magpie.FileMetadata
  alias Magpie.Storage

  @client Client.new("fake-token")

  describe "put/4" do
    test "uploads in-memory content in one request" do
      Req.Test.stub(Magpie, fn conn ->
        assert conn.request_path == "/2/files/upload"
        assert Req.Test.raw_body(conn) == "hello world"

        [arg] = Plug.Conn.get_req_header(conn, "dropbox-api-arg")
        assert %{"path" => "/hello.txt", "mode" => "overwrite"} = Jason.decode!(arg)

        Req.Test.json(conn, %{"name" => "hello.txt", "rev" => "1", "size" => 11})
      end)

      assert {:ok, %FileMetadata{name: "hello.txt", size: 11}} =
               Storage.put(@client, "/hello.txt", {:binary, ["hello", " ", "world"]},
                 mode: "overwrite"
               )
    end

    test "rechunks an arbitrary stream and commits its tail" do
      test_pid = self()

      Req.Test.stub(Magpie, fn conn ->
        [arg] = Plug.Conn.get_req_header(conn, "dropbox-api-arg")
        arg = Jason.decode!(arg)
        body = Req.Test.raw_body(conn)

        case conn.request_path do
          "/2/files/upload_session/start" ->
            assert body == ""
            Req.Test.json(conn, %{"session_id" => "session-1"})

          "/2/files/upload_session/append_v2" ->
            send(test_pid, {:append, arg["cursor"]["offset"], body})
            Plug.Conn.send_resp(conn, 200, "")

          "/2/files/upload_session/finish" ->
            send(test_pid, {:finish, arg["cursor"]["offset"], body, arg["commit"]})
            Req.Test.json(conn, %{"name" => "stream.bin", "rev" => "2", "size" => 9})
        end
      end)

      source = Stream.map(["ab", ["cd", "efg"], "hi"], & &1)

      assert {:ok, %FileMetadata{name: "stream.bin", size: 9}} =
               Storage.put(@client, "/stream.bin", {:stream, source}, chunk_size: 4)

      assert_received {:append, 0, "abcd"}
      assert_received {:append, 4, "efgh"}

      assert_received {:finish, 8, "i",
                       %{"path" => "/stream.bin", "mode" => "add", "autorename" => true}}
    end

    test "uses an upload session for large iodata" do
      test_pid = self()

      Req.Test.stub(Magpie, fn conn ->
        body = Req.Test.raw_body(conn)

        case conn.request_path do
          "/2/files/upload_session/start" ->
            Req.Test.json(conn, %{"session_id" => "session-2"})

          "/2/files/upload_session/append_v2" ->
            send(test_pid, {:chunk, body})
            Plug.Conn.send_resp(conn, 200, "")

          "/2/files/upload_session/finish" ->
            send(test_pid, {:tail, body})
            Req.Test.json(conn, %{"name" => "large.bin", "rev" => "3", "size" => 7})
        end
      end)

      assert {:ok, %FileMetadata{size: 7}} =
               Storage.put(@client, "/large.bin", {:binary, ["abc", "defg"]},
                 session_threshold: 4,
                 chunk_size: 4
               )

      assert_received {:chunk, "abcd"}
      assert_received {:tail, "efg"}
    end
  end

  describe "get/3 and download/4" do
    test "get returns only bytes by default and can retain response headers" do
      Req.Test.stub(Magpie, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("dropbox-api-result", ~s({"name":"a.txt"}))
        |> Plug.Conn.send_resp(200, "contents")
      end)

      assert {:ok, "contents"} = Storage.get(@client, "/a.txt")

      assert {:ok, %{body: "contents", headers: headers}} =
               Storage.get(@client, "/a.txt", with_headers: true)

      assert headers["dropbox-api-result"] == [~s({"name":"a.txt"})]
    end

    @tag :tmp_dir
    test "download streams chunks to disk and creates parents on request", %{tmp_dir: dir} do
      destination = Path.join([dir, "nested", "archive.bin"])

      Req.Test.stub(Magpie, fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "first-")
        {:ok, conn} = Plug.Conn.chunk(conn, "second")
        conn
      end)

      assert {:ok, ^destination} =
               Storage.download(@client, "/archive.bin", destination, mkdir_p: true)

      assert File.read!(destination) == "first-second"
      assert Path.wildcard(destination <> ".magpie-*.part") == []
    end

    @tag :tmp_dir
    test "download preserves an existing destination on API errors", %{tmp_dir: dir} do
      destination = Path.join(dir, "keep.txt")
      File.write!(destination, "original")

      Req.Test.stub(Magpie, fn conn ->
        conn
        |> Plug.Conn.put_status(409)
        |> Req.Test.json(%{"error_summary" => "path/not_found/.."})
      end)

      assert {:error, %Error{status: 409}} =
               Storage.download(@client, "/missing.txt", destination)

      assert File.read!(destination) == "original"
      assert Path.wildcard(destination <> ".magpie-*.part") == []
    end
  end

  describe "metadata and listing conveniences" do
    test "exists? distinguishes missing paths from other failures" do
      Req.Test.stub(Magpie, fn conn ->
        [path] = conn.body_params["path"] |> List.wrap()

        case path do
          "/present" ->
            Req.Test.json(conn, %{"name" => "present", "rev" => "1", "size" => 1})

          "/missing" ->
            conn
            |> Plug.Conn.put_status(409)
            |> Req.Test.json(%{
              "error_summary" => "path/not_found/..",
              "error" => %{".tag" => "path", "path" => %{".tag" => "not_found"}}
            })

          "/forbidden" ->
            conn
            |> Plug.Conn.put_status(403)
            |> Req.Test.json(%{"error_summary" => "access_error/.."})
        end
      end)

      assert Storage.exists?(@client, "/present")
      refute Storage.exists?(@client, "/missing")
      assert {:error, %Error{status: 403}} = Storage.exists?(@client, "/forbidden")
    end

    test "delete forwards parent_rev and returns typed metadata" do
      Req.Test.stub(Magpie, fn conn ->
        assert conn.body_params == %{"path" => "/old.txt", "parent_rev" => "rev-1"}

        Req.Test.json(conn, %{
          "metadata" => %{".tag" => "file", "name" => "old.txt", "rev" => "rev-1", "size" => 2}
        })
      end)

      assert {:ok, %FileMetadata{name: "old.txt"}} =
               Storage.delete(@client, "/old.txt", parent_rev: "rev-1")
    end

    test "list follows cursor pages and stream stays lazy" do
      Req.Test.stub(Magpie, fn conn ->
        case conn.request_path do
          "/2/files/list_folder" ->
            Req.Test.json(conn, %{
              "entries" => [%{".tag" => "file", "name" => "one", "rev" => "1", "size" => 1}],
              "cursor" => "next",
              "has_more" => true
            })

          "/2/files/list_folder/continue" ->
            Req.Test.json(conn, %{
              "entries" => [%{".tag" => "file", "name" => "two", "rev" => "2", "size" => 2}],
              "cursor" => "done",
              "has_more" => false
            })
        end
      end)

      assert {:ok, [%FileMetadata{name: "one"}, %FileMetadata{name: "two"}]} =
               Storage.list(@client, "/prefix", recursive: true)

      assert [%FileMetadata{name: "one"}] =
               @client |> Storage.stream("/prefix") |> Enum.take(1)
    end
  end

  describe "temporary URLs and bang variants" do
    test "url and upload_url unwrap Dropbox link responses" do
      Req.Test.stub(Magpie, fn conn ->
        case conn.request_path do
          "/2/files/get_temporary_link" ->
            Req.Test.json(conn, %{"link" => "https://download.example/a"})

          "/2/files/get_temporary_upload_link" ->
            assert conn.body_params["duration"] == 60
            assert conn.body_params["commit_info"]["path"] == "/a.txt"
            Req.Test.json(conn, %{"link" => "https://upload.example/a"})
        end
      end)

      assert {:ok, "https://download.example/a"} = Storage.url(@client, "/a.txt")

      assert "https://upload.example/a" =
               Storage.upload_url!(@client, "/a.txt", duration: 60)
    end

    test "bang variants raise normalized Dropbox errors" do
      Req.Test.stub(Magpie, fn conn ->
        conn
        |> Plug.Conn.put_status(409)
        |> Req.Test.json(%{"error_summary" => "path/not_found/.."})
      end)

      assert_raise Error, ~r/path\/not_found/, fn -> Storage.get!(@client, "/missing") end
    end
  end

  describe "error helpers" do
    test "classify common Dropbox errors without exact summary matching" do
      not_found =
        Error.new(409, %{
          "error" => %{".tag" => "path", "path" => %{".tag" => "not_found"}}
        })

      assert Error.not_found?(not_found)
      refute Error.conflict?(not_found)
      assert Error.conflict?(Error.new(409, %{"error_summary" => "path/conflict/file/.."}))
      assert Error.rate_limited?(Error.new(429, "slow down"))
      assert Error.auth?(Error.new(400, %{"error" => "invalid_grant"}))
      assert Error.retryable?(Error.new(503, "unavailable"))
      refute Error.retryable?(Error.new(409, "conflict"))
    end
  end
end
