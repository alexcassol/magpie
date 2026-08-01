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
  end
end
