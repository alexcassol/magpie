defmodule MagpieCoverageTest do
  @moduledoc """
  Table-driven smoke tests: every wrapper must hit its exact Dropbox route.
  """
  use ExUnit.Case, async: true

  @client Magpie.Client.new("fake-token")

  @member %{".tag" => "email", "email" => "a@b.com"}

  # {module, function, args (after client), expected API path}
  @rpc [
    {Magpie.Accounts, :set_profile_photo, ["QmFzZTY0"], "/account/set_profile_photo"},
    {Magpie.Accounts, :delete_profile_photo, [], "/account/delete_profile_photo"},
    {Magpie.Auth, :token_revoke, [], "/auth/token/revoke"},
    {Magpie.Check, :user, [], "/check/user"},
    {Magpie.Contacts, :delete_manual_contacts, [], "/contacts/delete_manual_contacts"},
    {Magpie.Contacts, :delete_manual_contacts_batch, [["a@b.com"]],
     "/contacts/delete_manual_contacts_batch"},
    {Magpie.OpenId, :userinfo, [], "/openid/userinfo"},
    {Magpie.FileProperties, :properties_add, ["/a", []], "/file_properties/properties/add"},
    {Magpie.FileProperties, :properties_overwrite, ["/a", []],
     "/file_properties/properties/overwrite"},
    {Magpie.FileProperties, :properties_remove, ["/a", []], "/file_properties/properties/remove"},
    {Magpie.FileProperties, :properties_search, [[]], "/file_properties/properties/search"},
    {Magpie.FileProperties, :properties_search_continue, ["c"],
     "/file_properties/properties/search/continue"},
    {Magpie.FileProperties, :properties_update, ["/a", []], "/file_properties/properties/update"},
    {Magpie.FileProperties, :templates_add_for_user, ["n", "d", []],
     "/file_properties/templates/add_for_user"},
    {Magpie.FileProperties, :templates_add_for_team, ["n", "d", []],
     "/file_properties/templates/add_for_team"},
    {Magpie.FileProperties, :templates_get_for_user, ["t"],
     "/file_properties/templates/get_for_user"},
    {Magpie.FileProperties, :templates_get_for_team, ["t"],
     "/file_properties/templates/get_for_team"},
    {Magpie.FileProperties, :templates_list_for_user, [],
     "/file_properties/templates/list_for_user"},
    {Magpie.FileProperties, :templates_list_for_team, [],
     "/file_properties/templates/list_for_team"},
    {Magpie.FileProperties, :templates_remove_for_user, ["t"],
     "/file_properties/templates/remove_for_user"},
    {Magpie.FileProperties, :templates_remove_for_team, ["t"],
     "/file_properties/templates/remove_for_team"},
    {Magpie.FileProperties, :templates_update_for_user, ["t"],
     "/file_properties/templates/update_for_user"},
    {Magpie.FileProperties, :templates_update_for_team, ["t"],
     "/file_properties/templates/update_for_team"},
    {Magpie.FileRequests, :count, [], "/file_requests/count"},
    {Magpie.FileRequests, :delete, [["id"]], "/file_requests/delete"},
    {Magpie.FileRequests, :delete_all_closed, [], "/file_requests/delete_all_closed"},
    {Magpie.FileRequests, :list_v2, [], "/file_requests/list_v2"},
    {Magpie.FileRequests, :list_continue, ["c"], "/file_requests/list/continue"},
    {Magpie.Files, :permanently_delete, ["/a"], "/files/permanently_delete"},
    {Magpie.Files, :get_temporary_upload_link, [%{"path" => "/a"}],
     "/files/get_temporary_upload_link"},
    {Magpie.Files.Tags, :add, ["/a", "tag"], "/files/tags/add"},
    {Magpie.Files.Tags, :get, [["/a"]], "/files/tags/get"},
    {Magpie.Files.Tags, :remove, ["/a", "tag"], "/files/tags/remove"},
    {Magpie.Files.Locks, :lock_file_batch, [[%{"path" => "/a"}]], "/files/lock_file_batch"},
    {Magpie.Files.Locks, :unlock_file_batch, [[%{"path" => "/a"}]], "/files/unlock_file_batch"},
    {Magpie.Files.Locks, :get_file_lock_batch, [[%{"path" => "/a"}]],
     "/files/get_file_lock_batch"},
    {Magpie.Files.MoveBatch, :move_batch, [[%{"from_path" => "/a", "to_path" => "/b"}]],
     "/files/move_batch_v2"},
    {Magpie.Files.MoveBatch, :check, ["j"], "/files/move_batch/check_v2"},
    {Magpie.Files.CreateFolderBatch, :create_folder_batch, [["/a"]],
     "/files/create_folder_batch"},
    {Magpie.Files.CreateFolderBatch, :check, ["j"], "/files/create_folder_batch/check"},
    {Magpie.Files.UploadSession, :start_batch, [2], "/files/upload_session/start_batch"},
    {Magpie.Users, :features_get_values, [[%{".tag" => "paper_as_files"}]],
     "/users/features/get_values"},
    {Magpie.Paper.Docs, :get_metadata, [%{"doc_id" => "x"}], "/paper/docs/get_metadata"},
    {Magpie.Sharing, :list_shared_links, [], "/sharing/list_shared_links"},
    {Magpie.Sharing, :get_shared_link_metadata, ["https://u"],
     "/sharing/get_shared_link_metadata"},
    {Magpie.Sharing, :modify_shared_link_settings, ["https://u", %{}],
     "/sharing/modify_shared_link_settings"},
    {Magpie.Sharing, :revoke_shared_link, ["https://u"], "/sharing/revoke_shared_link"},
    {Magpie.Sharing, :get_file_metadata, ["id:1"], "/sharing/get_file_metadata"},
    {Magpie.Sharing, :get_file_metadata_batch, [["id:1"]], "/sharing/get_file_metadata/batch"},
    {Magpie.Sharing, :add_file_member, ["id:1", [@member]], "/sharing/add_file_member"},
    {Magpie.Sharing, :list_file_members, ["id:1"], "/sharing/list_file_members"},
    {Magpie.Sharing, :list_file_members_batch, [["id:1"]], "/sharing/list_file_members/batch"},
    {Magpie.Sharing, :list_file_members_continue, ["c"], "/sharing/list_file_members/continue"},
    {Magpie.Sharing, :remove_file_member, ["id:1", @member], "/sharing/remove_file_member_2"},
    {Magpie.Sharing, :update_file_member, ["id:1", @member, "viewer"],
     "/sharing/update_file_member"},
    {Magpie.Sharing, :update_file_policy, ["id:1"], "/sharing/update_file_policy"},
    {Magpie.Sharing, :relinquish_file_membership, ["id:1"],
     "/sharing/relinquish_file_membership"},
    {Magpie.Sharing, :relinquish_access, ["id:1"], "/sharing/relinquish_access"},
    {Magpie.Sharing, :unshare_file, ["id:1"], "/sharing/unshare_file"},
    {Magpie.Sharing, :list_received_files, [], "/sharing/list_received_files"},
    {Magpie.Sharing, :list_received_files_continue, ["c"],
     "/sharing/list_received_files/continue"},
    {Magpie.Sharing, :share_folder, ["/a"], "/sharing/share_folder"},
    {Magpie.Sharing, :get_folder_metadata, ["sf1"], "/sharing/get_folder_metadata"},
    {Magpie.Sharing, :add_folder_member, ["sf1", []], "/sharing/add_folder_member"},
    {Magpie.Sharing, :list_folder_members, ["sf1"], "/sharing/list_folder_members"},
    {Magpie.Sharing, :list_folder_members_continue, ["c"],
     "/sharing/list_folder_members/continue"},
    {Magpie.Sharing, :list_folders, [], "/sharing/list_folders"},
    {Magpie.Sharing, :list_folders_continue, ["c"], "/sharing/list_folders/continue"},
    {Magpie.Sharing, :list_mountable_folders, [], "/sharing/list_mountable_folders"},
    {Magpie.Sharing, :list_mountable_folders_continue, ["c"],
     "/sharing/list_mountable_folders/continue"},
    {Magpie.Sharing, :mount_folder, ["sf1"], "/sharing/mount_folder"},
    {Magpie.Sharing, :unmount_folder, ["sf1"], "/sharing/unmount_folder"},
    {Magpie.Sharing, :relinquish_folder_membership, ["sf1"],
     "/sharing/relinquish_folder_membership"},
    {Magpie.Sharing, :remove_folder_member, ["sf1", @member], "/sharing/remove_folder_member"},
    {Magpie.Sharing, :update_folder_member, ["sf1", @member, "editor"],
     "/sharing/update_folder_member"},
    {Magpie.Sharing, :update_folder_policy, ["sf1"], "/sharing/update_folder_policy"},
    {Magpie.Sharing, :set_access_inheritance, ["sf1"], "/sharing/set_access_inheritance"},
    {Magpie.Sharing, :transfer_folder, ["sf1", "dbid:x"], "/sharing/transfer_folder"},
    {Magpie.Sharing, :unshare_folder, ["sf1"], "/sharing/unshare_folder"},
    {Magpie.Sharing, :check_job_status, ["j"], "/sharing/check_job_status"},
    {Magpie.Sharing, :check_remove_member_job_status, ["j"],
     "/sharing/check_remove_member_job_status"},
    {Magpie.Sharing, :check_share_job_status, ["j"], "/sharing/check_share_job_status"},
    {Magpie.Files, :copy, ["/a", "/b"], "/files/copy_v2"},
    {Magpie.Files, :restore, ["/a", "rev1"], "/files/restore"},
    {Magpie.Files, :delete_folder, ["/a"], "/files/delete_v2"},
    {Magpie.Files, :get_metadata, ["/a"], "/files/get_metadata"},
    {Magpie.Files, :get_temporary_link, ["/a"], "/files/get_temporary_link"},
    {Magpie.Files, :get_thumbnail_batch, [[%{"path" => "/a.jpg"}]], "/files/get_thumbnail_batch"},
    {Magpie.Files.ListFolder, :list_folder_continue, ["c"], "/files/list_folder/continue"},
    {Magpie.Files.ListFolder, :list_revisions, ["/a"], "/files/list_revisions"},
    {Magpie.Files.ListFolder, :get_latest_cursor, ["/a"], "/files/list_folder/get_latest_cursor"},
    {Magpie.Files.ListFolder, :longpoll, ["c"], "/files/list_folder/longpoll"},
    {Magpie.Files.CopyBatch, :copy_batch, ["/a", "/b"], "/files/copy_batch_v2"},
    {Magpie.Files.CopyBatch, :check, ["j"], "/files/copy_batch/check_v2"},
    {Magpie.Files.CopyReference, :get, ["/a"], "/files/copy_reference/get"},
    {Magpie.Files.CopyReference, :save, ["ref", "/a"], "/files/copy_reference/save"},
    {Magpie.Files.DeleteBatch, :delete_batch, [[%{"path" => "/a"}]], "/files/delete_batch"},
    {Magpie.Files.DeleteBatch, :check, ["j"], "/files/delete_batch/check"},
    {Magpie.Files.SaveUrl, :save_url, ["/a", "http://x"], "/files/save_url"},
    {Magpie.Files.SaveUrl, :check_job_status, ["j"], "/files/save_url/check_job_status"},
    {Magpie.Files.UploadSession, :finish_batch, [[]], "/files/upload_session/finish_batch_v2"},
    {Magpie.Files.UploadSession, :finish_batch_check, ["j"],
     "/files/upload_session/finish_batch/check"},
    {Magpie.FileRequests, :create, ["t", "/dest", %{"deadline" => "2027-01-01T00:00:00Z"}],
     "/file_requests/create"},
    {Magpie.FileRequests, :get, ["id"], "/file_requests/get"},
    {Magpie.FileRequests, :list, [], "/file_requests/list"},
    {Magpie.FileRequests, :update, ["id", "t", "/dest", %{}], "/file_requests/update"},
    {Magpie.Users, :get_account, ["dbid:x"], "/users/get_account"},
    {Magpie.Paper.Docs, :docs_archive, ["d"], "/paper/docs/archive"},
    {Magpie.Paper.Docs, :get_folder_info, ["d"], "/paper/docs/get_folder_info"},
    {Magpie.Paper.Docs, :docs_list, [], "/paper/docs/list"},
    {Magpie.Paper.Docs, :permanently_delete, ["d"], "/paper/docs/permanently_delete"},
    {Magpie.Paper.FolderUsers, :list, ["d"], "/paper/docs/folder_users/list"},
    {Magpie.Paper.FolderUsers, :list_continue, ["d", "c"],
     "/paper/docs/folder_users/list/continue"},
    {Magpie.Paper.SharingPolicy, :get, ["d"], "/paper/docs/sharing_policy/get"},
    {Magpie.Paper.SharingPolicy, :set, ["d", %{}], "/paper/docs/sharing_policy/set"},
    {Magpie.Paper.Users, :add, ["d", [], "hi", false], "/paper/docs/users/add"},
    {Magpie.Paper.Users, :list, ["d"], "/paper/docs/users/list"},
    {Magpie.Paper.Users, :list_continue, ["d", "c"], "/paper/docs/users/list/continue"},
    {Magpie.Paper.Users, :remove, ["d", %{}], "/paper/docs/users/remove"}
  ]

  # download-style content endpoints: args go in the Dropbox-API-Arg header
  @download [
    {Magpie.Accounts, :get_photo, ["dbid:x"], "/account/get_photo"},
    {Magpie.Files, :download_zip, ["/a"], "/files/download_zip"},
    {Magpie.Files, :export, ["/a"], "/files/export"},
    {Magpie.Files, :get_thumbnail_v2, [%{".tag" => "path", "path" => "/a.jpg"}],
     "/files/get_thumbnail_v2"},
    {Magpie.Sharing, :get_shared_link_file, ["https://u"], "/sharing/get_shared_link_file"},
    {Magpie.Files, :get_thumbnail, ["/a.jpg"], "/files/get_thumbnail"},
    {Magpie.Files, :get_preview, ["/a.pdf"], "/files/get_preview"},
    {Magpie.Paper.Docs, :docs_download, ["d", "markdown"], "/paper/docs/download"}
  ]

  test "every RPC wrapper hits its exact route" do
    for {mod, fun, args, path} <- @rpc do
      Req.Test.stub(Magpie, fn conn ->
        assert conn.request_path == "/2" <> path,
               "#{inspect(mod)}.#{fun} hit #{conn.request_path}, expected /2#{path}"

        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, _} = apply(mod, fun, [@client | args]), "#{inspect(mod)}.#{fun} failed"
    end
  end

  test "every download wrapper hits its exact route with Dropbox-API-Arg" do
    for {mod, fun, args, path} <- @download do
      Req.Test.stub(Magpie, fn conn ->
        assert conn.request_path == "/2" <> path,
               "#{inspect(mod)}.#{fun} hit #{conn.request_path}, expected /2#{path}"

        assert [_] = Plug.Conn.get_req_header(conn, "dropbox-api-arg"),
               "#{inspect(mod)}.#{fun} did not send Dropbox-API-Arg"

        Plug.Conn.send_resp(conn, 200, "bytes")
      end)

      assert %{body: "bytes"} = apply(mod, fun, [@client | args]),
             "#{inspect(mod)}.#{fun} failed"
    end
  end

  test "check/app uses basic auth with the app credentials" do
    Req.Test.stub(Magpie, fn conn ->
      assert conn.request_path == "/2/check/app"

      assert Plug.Conn.get_req_header(conn, "authorization") ==
               ["Basic " <> Base.encode64("key:secret")]

      Req.Test.json(conn, %{"result" => "ping"})
    end)

    assert {:ok, %{"result" => "ping"}} = Magpie.Check.app("key", "secret")
  end

  test "upload_session/append_batch sends raw concatenated data" do
    entries = [%{"cursor" => %{"session_id" => "s", "offset" => 0}, "length" => 4}]

    Req.Test.stub(Magpie, fn conn ->
      assert conn.request_path == "/2/files/upload_session/append_batch"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == "data"
      Req.Test.json(conn, %{"entries" => []})
    end)

    assert {:ok, _} = Magpie.Files.UploadSession.append_batch(@client, entries, "data")
  end

  @tag :tmp_dir
  test "files/paper/create uploads the local file", %{tmp_dir: dir} do
    local = Path.join(dir, "doc.md")
    File.write!(local, "# Title")

    Req.Test.stub(Magpie, fn conn ->
      assert conn.request_path == "/2/files/paper/create"

      [arg] = Plug.Conn.get_req_header(conn, "dropbox-api-arg")
      assert %{"path" => "/doc.md", "import_format" => "markdown"} = Jason.decode!(arg)

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == "# Title"

      Req.Test.json(conn, %{"url" => "https://paper"})
    end)

    assert {:ok, _} = Magpie.Files.Paper.create(@client, "/doc.md", local)
  end
end
