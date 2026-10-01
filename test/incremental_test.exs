defmodule Magpie.IncrementalTest do
  use ExUnit.Case, async: true
  alias Magpie.{Client, Storage, ListPage, CursorError, Error}
  @client Client.new("fake-token")

  defp page(conn, entries, cursor, more),
    do: Req.Test.json(conn, %{"entries" => entries, "cursor" => cursor, "has_more" => more})

  test "fetches only one page, resumes saved checkpoints, drains empty pages and polls final cursor" do
    pid = self()

    Req.Test.stub(Magpie, fn conn ->
      body = Jason.decode!(Req.Test.raw_body(conn))
      send(pid, {:request, conn.request_path, body})

      case body do
        %{"path" => "", "recursive" => true, "include_deleted" => true, "limit" => 2} ->
          page(
            conn,
            [
              %{".tag" => "file", "name" => "a", "rev" => "1"},
              %{".tag" => "folder", "name" => "b"}
            ],
            "one",
            true
          )

        %{"cursor" => "one"} ->
          page(conn, [], "two", true)

        %{"cursor" => "two"} ->
          page(conn, [%{".tag" => "deleted", "name" => "a"}], "final", false)

        %{"cursor" => "final"} ->
          page(conn, [%{".tag" => "file", "name" => "new", "rev" => "2"}], "later", false)

        %{"cursor" => "later"} ->
          page(conn, [], "idle", false)
      end
    end)

    assert {:ok,
            %ListPage{
              entries: [%Magpie.FileMetadata{}, %Magpie.FolderMetadata{}],
              cursor: saved,
              has_more: true
            }} =
             Storage.list_page(@client, "", recursive: true, include_deleted: true, limit: 2)

    assert_received {:request, "/2/files/list_folder", _}
    refute_received {:request, _, _}
    # The application can persist this plain binary and resume with a new client.
    assert {:ok, %ListPage{entries: [], cursor: "two", has_more: true}} =
             Storage.continue_list(Client.new("another-token"), saved)

    assert {:ok,
            %ListPage{entries: [%Magpie.DeletedMetadata{}], cursor: "final", has_more: false}} =
             Storage.continue_list(@client, "two")

    assert {:ok, %ListPage{cursor: "later", entries: [%Magpie.FileMetadata{name: "new"}]}} =
             Storage.continue_list(@client, "final")

    assert {:ok, %ListPage{entries: [], cursor: "idle", has_more: false}} =
             Storage.continue_list(@client, "later")
  end

  test "empty initial page and legacy list/stream contracts" do
    Req.Test.stub(Magpie, &page(&1, [], "end", false))
    assert {:ok, %ListPage{entries: [], has_more: false}} = Storage.list_page(@client)
    assert {:ok, []} = Storage.list(@client)
    assert [] = Enum.to_list(Storage.stream(@client))
    Req.Test.stub(Magpie, &page(&1, [%{".tag" => "deleted", "name" => "gone"}], "end", false))
    assert {:ok, [%Magpie.DeletedMetadata{}]} = Storage.list(@client)
    assert [%Magpie.DeletedMetadata{}] = Enum.to_list(Storage.stream(@client))
  end

  test "API and transport errors on first and continuation pages retain their types" do
    for fetch <- [
          fn -> Storage.list_page(@client) end,
          fn -> Storage.continue_list(@client, "saved") end
        ] do
      Req.Test.stub(Magpie, fn conn ->
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error_summary" => "unavailable"})
      end)

      assert {:error, %Error{status: 503}} = fetch.()
      Req.Test.stub(Magpie, &Req.Test.transport_error(&1, :timeout))
      assert {:error, %Req.TransportError{reason: :timeout}} = fetch.()
    end
  end

  test "reset explicitly requires reconstruction, preserves diagnostics and never restarts" do
    pid = self()

    Req.Test.stub(Magpie, fn conn ->
      assert conn.request_path == "/2/files/list_folder/continue"
      send(pid, :continued)

      conn
      |> Plug.Conn.put_status(409)
      |> Plug.Conn.put_resp_header("x-dropbox-request-id", "r1")
      |> Req.Test.json(%{"error" => %{".tag" => "reset"}, "error_summary" => "reset/.."})
    end)

    assert {:error,
            %CursorError{rebuild_required: true, reason: :reset, error: %Error{request_id: "r1"}}} =
             Storage.continue_list(@client, "expired")

    assert_received :continued
    refute_received :continued
    # Low-level APIs and legacy stream/list keep the 0.7 error contract.
    assert {:error, %Error{status: 409}} =
             Magpie.Files.ListFolder.list_folder_continue(@client, "expired")
  end

  test "path and malformed cursor API errors are not inferred to be reset" do
    for {status, body} <- [
          {409, %{"error" => %{".tag" => "path", "path" => %{".tag" => "not_found"}}}},
          {400, "invalid cursor"}
        ] do
      Req.Test.stub(Magpie, fn conn ->
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
      end)

      assert {:error, %Error{status: ^status}} = Storage.continue_list(@client, "bad")
    end

    for cursor <- [nil, "", 42] do
      assert_raise ArgumentError, fn -> Storage.continue_list(@client, cursor) end
    end

    assert_raise ArgumentError, fn -> Storage.continue_list(@client, "saved", recursive: true) end
    assert_raise ArgumentError, fn -> Storage.list_page(@client, "", typo: true) end
  end

  test "operation request settings take precedence" do
    Req.Test.stub(:incremental_override, &page(&1, [], "end", false))

    assert {:ok, %ListPage{}} =
             Storage.list_page(@client, "",
               request: [req_options: [plug: {Req.Test, :incremental_override}]]
             )

    assert {:ok, %ListPage{}} =
             Storage.continue_list(@client, "saved",
               request: [req_options: [plug: {Req.Test, :incremental_override}]]
             )
  end
end
