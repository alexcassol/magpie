defmodule MagpieTest do
  use ExUnit.Case, async: true

  alias Magpie.Client

  @client Client.new("fake-token")

  describe "Client" do
    test "new/0 builds an empty client" do
      assert %Client{access_token: nil} = Client.new()
    end

    test "new/1 stores the access token" do
      assert %Client{access_token: "fake-token"} = Client.new("fake-token")
    end
  end

  describe "post/3" do
    test "returns {:ok, body} on 200 and sends JSON body with bearer auth" do
      Req.Test.stub(Magpie, fn conn ->
        assert conn.request_path == "/2/files/create_folder_v2"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fake-token"]

        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{"path" => "/Photos"}

        Req.Test.json(conn, %{"metadata" => %{"name" => "Photos"}})
      end)

      assert {:ok, %{"metadata" => %{"name" => "Photos"}}} =
               Magpie.post(@client, "/files/create_folder_v2", %{"path" => "/Photos"})
    end

    test "returns {{:status_code, code}, body} on API errors" do
      Req.Test.stub(Magpie, fn conn ->
        conn
        |> Plug.Conn.put_status(409)
        |> Req.Test.json(%{"error_summary" => "path/conflict/folder/.."})
      end)

      assert {{:status_code, 409}, %{"error_summary" => _}} =
               Magpie.post(@client, "/files/create_folder_v2", %{"path" => "/Photos"})
    end
  end

  describe "Files" do
    test "create_folder/2 posts to /files/create_folder_v2" do
      Req.Test.stub(Magpie, fn conn ->
        assert conn.request_path == "/2/files/create_folder_v2"
        Req.Test.json(conn, %{"metadata" => %{"name" => "Backup"}})
      end)

      assert {:ok, %{"metadata" => _}} = Magpie.Files.create_folder(@client, "/Backup")
    end

    @tag :tmp_dir
    test "upload/3 streams the local file as the raw request body", %{tmp_dir: dir} do
      local = Path.join(dir, "hello.txt")
      File.write!(local, "hello dropbox")

      Req.Test.stub(Magpie, fn conn ->
        assert conn.request_path == "/2/files/upload"
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/octet-stream"]

        [arg] = Plug.Conn.get_req_header(conn, "dropbox-api-arg")
        assert %{"path" => "/hello.txt", "mode" => "add"} = Jason.decode!(arg)

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == "hello dropbox"

        Req.Test.json(conn, %{"name" => "hello.txt", "size" => 13})
      end)

      assert {:ok, %{"name" => "hello.txt"}} = Magpie.Files.upload(@client, "/hello.txt", local)
    end

    test "move/3 posts to /files/move_v2" do
      Req.Test.stub(Magpie, fn conn ->
        assert conn.request_path == "/2/files/move_v2"
        Req.Test.json(conn, %{"metadata" => %{"name" => "algebra"}})
      end)

      assert {:ok, %{"metadata" => _}} = Magpie.Files.move(@client, "/math", "/algebra")
    end

    test "search/3 posts query and options to /files/search_v2" do
      Req.Test.stub(Magpie, fn conn ->
        assert conn.request_path == "/2/files/search_v2"

        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert %{"query" => "report", "options" => %{"path" => "/docs"}} = Jason.decode!(raw)

        Req.Test.json(conn, %{"matches" => []})
      end)

      assert {:ok, %{"matches" => []}} =
               Magpie.Files.search(@client, "report", %{"path" => "/docs"})
    end

    test "download/2 returns raw body and headers" do
      Req.Test.stub(Magpie, fn conn ->
        assert conn.request_path == "/2/files/download"
        assert [_] = Plug.Conn.get_req_header(conn, "dropbox-api-arg")
        Plug.Conn.send_resp(conn, 200, "file-contents")
      end)

      assert %{body: "file-contents", headers: _} = Magpie.Files.download(@client, "/backup.zip")
    end
  end

  describe "Files.ListFolder" do
    test "list_folder/2 returns folder entries" do
      Req.Test.stub(Magpie, fn conn ->
        assert conn.request_path == "/2/files/list_folder"
        Req.Test.json(conn, %{"entries" => [%{".tag" => "folder", "name" => "Backup"}]})
      end)

      assert {:ok, %{"entries" => [%{"name" => "Backup"}]}} =
               Magpie.Files.ListFolder.list_folder(@client, "")
    end
  end

  describe "Sharing" do
    test "create_shared_link/3 posts settings to create_shared_link_with_settings" do
      Req.Test.stub(Magpie, fn conn ->
        assert conn.request_path == "/2/sharing/create_shared_link_with_settings"

        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert %{"path" => "/report.pdf", "settings" => %{}} = Jason.decode!(raw)

        Req.Test.json(conn, %{"url" => "https://www.dropbox.com/s/abc/report.pdf"})
      end)

      assert {:ok, %{"url" => "https://" <> _}} =
               Magpie.Sharing.create_shared_link(@client, "/report.pdf")
    end
  end

  describe "Users" do
    test "current_account/1 returns the account map" do
      Req.Test.stub(Magpie, fn conn ->
        assert conn.request_path == "/2/users/get_current_account"
        Req.Test.json(conn, %{"account_id" => "dbid:123", "email" => "user@example.com"})
      end)

      assert %{"account_id" => "dbid:123"} = Magpie.Users.current_account(@client)
    end

    test "current_account/1 returns error tuple on failure" do
      Req.Test.stub(Magpie, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error_summary" => "invalid_access_token/"})
      end)

      assert {:error, {401, %{"error_summary" => _}}} = Magpie.Users.current_account(@client)
    end

    test "get_space_usage/1 and get_account_batch/2 unwrap successful responses" do
      Req.Test.stub(Magpie, fn conn ->
        case conn.request_path do
          "/2/users/get_space_usage" -> Req.Test.json(conn, %{"used" => 10})
          "/2/users/get_account_batch" -> Req.Test.json(conn, [%{"account_id" => "dbid:1"}])
        end
      end)

      assert %{"used" => 10} = Magpie.Users.get_space_usage(@client)
      assert [%{"account_id" => "dbid:1"}] = Magpie.Users.get_account_batch(@client, ["dbid:1"])
    end

    test "current_account_to_struct/1 and get_space_usage_to_struct/1 build structs" do
      Req.Test.stub(Magpie, fn conn ->
        case conn.request_path do
          "/2/users/get_current_account" ->
            Req.Test.json(conn, %{"account_id" => "dbid:1", "email" => "a@b.com"})

          "/2/users/get_space_usage" ->
            Req.Test.json(conn, %{"used" => 10, "allocation" => %{"allocated" => 100}})
        end
      end)

      assert %Magpie.Account{account_id: "dbid:1", email: "a@b.com"} =
               Magpie.Users.current_account_to_struct(@client)

      assert %Magpie.SpaceUsage{used: 10} = Magpie.Users.get_space_usage_to_struct(@client)
    end

    test "get_account_to_struct/2 builds a struct and rescues failures" do
      Req.Test.stub(Magpie, fn conn ->
        assert conn.request_path == "/2/users/get_account"
        Req.Test.json(conn, %{"account_id" => "dbid:9"})
      end)

      assert %Magpie.Account{account_id: "dbid:9"} =
               Magpie.Users.get_account_to_struct(@client, "dbid:9")

      Req.Test.stub(Magpie, fn conn ->
        conn |> Plug.Conn.put_status(409) |> Req.Test.json(%{"error_summary" => "no/"})
      end)

      assert {:error, _} = Magpie.Users.get_account_to_struct(@client, "dbid:9")
    end
  end

  describe "struct helpers" do
    test "Files.create_folder_to_struct/2 returns a Folder struct" do
      Req.Test.stub(Magpie, fn conn ->
        Req.Test.json(conn, %{"id" => "id:1", "name" => "Backup", "path_lower" => "/backup"})
      end)

      assert %Magpie.Folder{id: "id:1", name: "Backup"} =
               Magpie.Files.create_folder_to_struct(@client, "/Backup")
    end

    test "Files.delete_folder_to_struct/2 returns an error tuple on failure" do
      Req.Test.stub(Magpie, fn conn ->
        conn
        |> Plug.Conn.put_status(409)
        |> Req.Test.json(%{"error_summary" => "path_lookup/not_found/"})
      end)

      assert {:error, {409, _}} = Magpie.Files.delete_folder_to_struct(@client, "/x")
    end

    test "Sharing.create_shared_link_to_struct/2 returns a SharedLink struct" do
      Req.Test.stub(Magpie, fn conn ->
        Req.Test.json(conn, %{"url" => "https://dbx/s/x", "path" => "/x"})
      end)

      assert %Magpie.SharedLink{url: "https://dbx/s/x"} =
               Magpie.Sharing.create_shared_link_to_struct(@client, "/x")
    end
  end

  describe "Utils" do
    test "to_struct/2 fills only known fields" do
      attrs = %{"name" => "Backup", "unknown" => "x"}

      assert %Magpie.Folder{name: "Backup", id: nil} =
               Magpie.Utils.to_struct(%Magpie.Folder{}, attrs)
    end

    test "get_header/2 returns the first matching header value" do
      assert Magpie.Utils.get_header([{"a", "1"}, {"b", "2"}], "b") == "2"
    end
  end

  describe "download errors" do
    test "download/2 returns the status tuple on API errors" do
      Req.Test.stub(Magpie, fn conn ->
        conn
        |> Plug.Conn.put_status(409)
        |> Req.Test.json(%{"error_summary" => "path/not_found/"})
      end)

      assert {{:status_code, 409}, _} = Magpie.Files.download(@client, "/missing.txt")
    end
  end

  describe "file-based upload session functions" do
    @tag :tmp_dir
    test "start/append/finish upload the local file contents", %{tmp_dir: dir} do
      local = Path.join(dir, "chunk.bin")
      File.write!(local, "chunk")

      Req.Test.stub(Magpie, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == "chunk"

        case conn.request_path do
          "/2/files/upload_session/start" -> Req.Test.json(conn, %{"session_id" => "s1"})
          "/2/files/upload_session/append_v2" -> Req.Test.json(conn, nil)
          "/2/files/upload_session/finish" -> Req.Test.json(conn, %{"name" => "chunk.bin"})
        end
      end)

      alias Magpie.Files.UploadSession
      assert {:ok, %{"session_id" => "s1"}} = UploadSession.start(@client, false, local)
      assert {:ok, _} = UploadSession.append(@client, "s1", false, local)
      assert {:ok, %{"name" => _}} = UploadSession.finish(@client, "s1", "/chunk.bin", local)
    end
  end

  describe "Files.Paper and Paper.Docs uploads" do
    @tag :tmp_dir
    test "Files.Paper.update uploads the local file", %{tmp_dir: dir} do
      local = Path.join(dir, "doc.md")
      File.write!(local, "# v2")

      Req.Test.stub(Magpie, fn conn ->
        assert conn.request_path == "/2/files/paper/update"
        [arg] = Plug.Conn.get_req_header(conn, "dropbox-api-arg")
        assert %{"doc_update_policy" => "update"} = Jason.decode!(arg)
        Req.Test.json(conn, %{"paper_revision" => 2})
      end)

      assert {:ok, %{"paper_revision" => 2}} =
               Magpie.Files.Paper.update(@client, "/doc.md", local)
    end

    @tag :tmp_dir
    test "Paper.Docs.docs_create and docs_update upload the local file", %{tmp_dir: dir} do
      local = Path.join(dir, "doc.md")
      File.write!(local, "# legacy")

      Req.Test.stub(Magpie, fn conn ->
        case conn.request_path do
          "/2/paper/docs/create" -> Req.Test.json(conn, %{"doc_id" => "d1"})
          "/2/paper/docs/update" -> Req.Test.json(conn, %{"doc_id" => "d1", "revision" => 2})
        end
      end)

      assert {:ok, %{"doc_id" => "d1"}} =
               Magpie.Paper.Docs.docs_create(@client, "markdown", nil, local)

      assert {:ok, %{"revision" => 2}} =
               Magpie.Paper.Docs.docs_update(@client, "d1", "update", 1, "markdown", local)
    end
  end
end
