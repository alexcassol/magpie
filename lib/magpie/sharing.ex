defmodule Magpie.Sharing do
  @moduledoc """
  Endpoints for creating and managing shared links and shared folders.
  """
  alias Magpie.Client
  import Magpie
  import Magpie.Utils

  @doc """
  Create a shared link with custom settings, returns a map.

  `settings` accepts the `SharedLinkSettings` fields, e.g.
  `%{"audience" => "public", "access" => "viewer"}`.

  ## Example

    Magpie.Sharing.create_shared_link client, "/Path"

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-create_shared_link_with_settings
  """
  @spec create_shared_link(Client.t(), binary, map) :: Magpie.response()
  def create_shared_link(client, path, settings \\ %{}) do
    body = %{"path" => path, "settings" => settings}
    post(client, "/sharing/create_shared_link_with_settings", body)
  end

  @doc """
  Create shared link returns SharedLink struct

  ## Example

    Magpie.Sharing.create_shared_link_to_struct client, "/Path"
  """
  @spec create_shared_link_to_struct(Client, binary) :: SharedLink | any
  def create_shared_link_to_struct(client, path) do
    case create_shared_link(client, path) do
      {:ok, response} -> to_struct(%Magpie.SharedLink{}, response)
      {{:status_code, status_code}, body} -> {:error, {status_code, body}}
    end
  end

  @doc """
  List shared links of this user. `opts` accepts `"path"`, `"cursor"` and
  `"direct_only"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-list_shared_links
  """
  def list_shared_links(client, opts \\ %{}) do
    post(client, "/sharing/list_shared_links", opts)
  end

  @doc """
  Get the metadata of a shared link. `opts` accepts `"path"` and
  `"link_password"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-get_shared_link_metadata
  """
  def get_shared_link_metadata(client, url, opts \\ %{}) do
    body = Map.merge(%{"url" => url}, opts)
    post(client, "/sharing/get_shared_link_metadata", body)
  end

  @doc """
  Download the shared link's file from a user's Dropbox. `opts` accepts
  `"path"` and `"link_password"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-get_shared_link_file
  """
  def get_shared_link_file(client, url, opts \\ %{}) do
    arg = Map.merge(%{"url" => url}, opts)
    headers = %{"Dropbox-API-Arg" => Jason.encode!(arg)}
    download_request(client, upload_url(), "sharing/get_shared_link_file", [], headers)
  end

  @doc """
  Modify the settings of a shared link. `settings` takes the
  `SharedLinkSettings` fields.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-modify_shared_link_settings
  """
  def modify_shared_link_settings(client, url, settings, remove_expiration \\ false) do
    body = %{"url" => url, "settings" => settings, "remove_expiration" => remove_expiration}
    post(client, "/sharing/modify_shared_link_settings", body)
  end

  @doc """
  Revoke a shared link.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-revoke_shared_link
  """
  def revoke_shared_link(client, url) do
    post(client, "/sharing/revoke_shared_link", %{"url" => url})
  end

  @doc """
  Returns shared file metadata. `file` is a path or file id; `opts` accepts
  `"actions"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-get_file_metadata
  """
  def get_file_metadata(client, file, opts \\ %{}) do
    body = Map.merge(%{"file" => file}, opts)
    post(client, "/sharing/get_file_metadata", body)
  end

  @doc """
  Returns shared file metadata for a batch of files.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-get_file_metadata-batch
  """
  def get_file_metadata_batch(client, files, opts \\ %{}) do
    body = Map.merge(%{"files" => files}, opts)
    post(client, "/sharing/get_file_metadata/batch", body)
  end

  @doc """
  Adds specified members to a file. `members` is a list of `MemberSelector`
  maps, e.g. `%{".tag" => "email", "email" => "a@b.com"}`; `opts` accepts
  `"custom_message"`, `"quiet"`, `"access_level"` and
  `"add_message_as_comment"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-add_file_member
  """
  def add_file_member(client, file, members, opts \\ %{}) do
    body = Map.merge(%{"file" => file, "members" => members}, opts)
    post(client, "/sharing/add_file_member", body)
  end

  @doc """
  List the members of a file. `opts` accepts `"actions"`,
  `"include_inherited"` and `"limit"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-list_file_members
  """
  def list_file_members(client, file, opts \\ %{}) do
    body = Map.merge(%{"file" => file}, opts)
    post(client, "/sharing/list_file_members", body)
  end

  @doc """
  List the members of multiple files at once.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-list_file_members-batch
  """
  def list_file_members_batch(client, files, opts \\ %{}) do
    body = Map.merge(%{"files" => files}, opts)
    post(client, "/sharing/list_file_members/batch", body)
  end

  @doc """
  Fetches the next page of results from `list_file_members/3`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-list_file_members-continue
  """
  def list_file_members_continue(client, cursor) do
    post(client, "/sharing/list_file_members/continue", %{"cursor" => cursor})
  end

  @doc """
  Removes a specified member from the file. `member` is a `MemberSelector`
  map.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-remove_file_member_2
  """
  def remove_file_member(client, file, member) do
    post(client, "/sharing/remove_file_member_2", %{"file" => file, "member" => member})
  end

  @doc """
  Changes a member's access on a shared file.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-update_file_member
  """
  def update_file_member(client, file, member, access_level) do
    body = %{"file" => file, "member" => member, "access_level" => access_level}
    post(client, "/sharing/update_file_member", body)
  end

  @doc """
  Changes the policies of a shared file. `opts` accepts `"actions"`,
  `"link_settings"` and `"viewer_info_policy"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-update_file_policy
  """
  def update_file_policy(client, file, opts \\ %{}) do
    body = Map.merge(%{"file" => file}, opts)
    post(client, "/sharing/update_file_policy", body)
  end

  @doc """
  The current user relinquishes their membership in a shared file.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-relinquish_file_membership
  """
  def relinquish_file_membership(client, file) do
    post(client, "/sharing/relinquish_file_membership", %{"file" => file})
  end

  @doc """
  The current user relinquishes their access to a file by id.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-relinquish_access
  """
  def relinquish_access(client, file_id) do
    post(client, "/sharing/relinquish_access", %{"file_id" => file_id})
  end

  @doc """
  Remove all members from this file (does not remove inherited membership).

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-unshare_file
  """
  def unshare_file(client, file) do
    post(client, "/sharing/unshare_file", %{"file" => file})
  end

  @doc """
  Returns a list of files shared with the current user. `opts` accepts
  `"limit"` and `"actions"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-list_received_files
  """
  def list_received_files(client, opts \\ %{}) do
    post(client, "/sharing/list_received_files", opts)
  end

  @doc """
  Fetches the next page of results from `list_received_files/2`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-list_received_files-continue
  """
  def list_received_files_continue(client, cursor) do
    post(client, "/sharing/list_received_files/continue", %{"cursor" => cursor})
  end

  @doc """
  Share a folder with collaborators. `opts` accepts the `ShareFolderArg`
  fields (`"acl_update_policy"`, `"member_policy"`, `"shared_link_policy"`,
  `"viewer_info_policy"`, `"access_inheritance"`, `"force_async"`, ...).

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-share_folder
  """
  def share_folder(client, path, opts \\ %{}) do
    body = Map.merge(%{"path" => path}, opts)
    post(client, "/sharing/share_folder", body)
  end

  @doc """
  Returns shared folder metadata. `opts` accepts `"actions"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-get_folder_metadata
  """
  def get_folder_metadata(client, shared_folder_id, opts \\ %{}) do
    body = Map.merge(%{"shared_folder_id" => shared_folder_id}, opts)
    post(client, "/sharing/get_folder_metadata", body)
  end

  @doc """
  Allows an owner/editor to add members to a shared folder. `members` is a
  list of `AddMember` maps; `opts` accepts `"quiet"` and `"custom_message"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-add_folder_member
  """
  def add_folder_member(client, shared_folder_id, members, opts \\ %{}) do
    body = Map.merge(%{"shared_folder_id" => shared_folder_id, "members" => members}, opts)
    post(client, "/sharing/add_folder_member", body)
  end

  @doc """
  List the members of a shared folder. `opts` accepts `"actions"` and
  `"limit"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-list_folder_members
  """
  def list_folder_members(client, shared_folder_id, opts \\ %{}) do
    body = Map.merge(%{"shared_folder_id" => shared_folder_id}, opts)
    post(client, "/sharing/list_folder_members", body)
  end

  @doc """
  Fetches the next page of results from `list_folder_members/3`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-list_folder_members-continue
  """
  def list_folder_members_continue(client, cursor) do
    post(client, "/sharing/list_folder_members/continue", %{"cursor" => cursor})
  end

  @doc """
  Return the list of all shared folders the current user has access to.
  `opts` accepts `"limit"` and `"actions"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-list_folders
  """
  def list_folders(client, opts \\ %{}) do
    post(client, "/sharing/list_folders", opts)
  end

  @doc """
  Fetches the next page of results from `list_folders/2`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-list_folders-continue
  """
  def list_folders_continue(client, cursor) do
    post(client, "/sharing/list_folders/continue", %{"cursor" => cursor})
  end

  @doc """
  Return the list of all shared folders the current user can mount or
  unmount. `opts` accepts `"limit"` and `"actions"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-list_mountable_folders
  """
  def list_mountable_folders(client, opts \\ %{}) do
    post(client, "/sharing/list_mountable_folders", opts)
  end

  @doc """
  Fetches the next page of results from `list_mountable_folders/2`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-list_mountable_folders-continue
  """
  def list_mountable_folders_continue(client, cursor) do
    post(client, "/sharing/list_mountable_folders/continue", %{"cursor" => cursor})
  end

  @doc """
  Mount a shared folder into the current user's Dropbox.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-mount_folder
  """
  def mount_folder(client, shared_folder_id) do
    post(client, "/sharing/mount_folder", %{"shared_folder_id" => shared_folder_id})
  end

  @doc """
  Unmount a shared folder from the current user's Dropbox.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-unmount_folder
  """
  def unmount_folder(client, shared_folder_id) do
    post(client, "/sharing/unmount_folder", %{"shared_folder_id" => shared_folder_id})
  end

  @doc """
  The current user relinquishes their membership in a shared folder.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-relinquish_folder_membership
  """
  def relinquish_folder_membership(client, shared_folder_id, leave_a_copy \\ false) do
    body = %{"shared_folder_id" => shared_folder_id, "leave_a_copy" => leave_a_copy}
    post(client, "/sharing/relinquish_folder_membership", body)
  end

  @doc """
  Removes a member from a shared folder. `member` is a `MemberSelector` map.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-remove_folder_member
  """
  def remove_folder_member(client, shared_folder_id, member, leave_a_copy \\ false) do
    body = %{
      "shared_folder_id" => shared_folder_id,
      "member" => member,
      "leave_a_copy" => leave_a_copy
    }

    post(client, "/sharing/remove_folder_member", body)
  end

  @doc """
  Changes a member's access on a shared folder.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-update_folder_member
  """
  def update_folder_member(client, shared_folder_id, member, access_level) do
    body = %{
      "shared_folder_id" => shared_folder_id,
      "member" => member,
      "access_level" => access_level
    }

    post(client, "/sharing/update_folder_member", body)
  end

  @doc """
  Update the sharing policies for a shared folder. `opts` accepts
  `"member_policy"`, `"acl_update_policy"`, `"viewer_info_policy"`,
  `"shared_link_policy"`, `"link_settings"` and `"actions"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-update_folder_policy
  """
  def update_folder_policy(client, shared_folder_id, opts \\ %{}) do
    body = Map.merge(%{"shared_folder_id" => shared_folder_id}, opts)
    post(client, "/sharing/update_folder_policy", body)
  end

  @doc """
  Sets the access inheritance of a shared folder (`"inherit"` or
  `"no_inherit"`).

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-set_access_inheritance
  """
  def set_access_inheritance(client, shared_folder_id, access_inheritance \\ "inherit") do
    body = %{
      "shared_folder_id" => shared_folder_id,
      "access_inheritance" => access_inheritance
    }

    post(client, "/sharing/set_access_inheritance", body)
  end

  @doc """
  Transfer ownership of a shared folder to another member.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-transfer_folder
  """
  def transfer_folder(client, shared_folder_id, to_dropbox_id) do
    body = %{"shared_folder_id" => shared_folder_id, "to_dropbox_id" => to_dropbox_id}
    post(client, "/sharing/transfer_folder", body)
  end

  @doc """
  Allows the owner to unshare a folder.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-unshare_folder
  """
  def unshare_folder(client, shared_folder_id, leave_a_copy \\ false) do
    body = %{"shared_folder_id" => shared_folder_id, "leave_a_copy" => leave_a_copy}
    post(client, "/sharing/unshare_folder", body)
  end

  @doc """
  Returns the status of an asynchronous sharing job.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-check_job_status
  """
  def check_job_status(client, async_job_id) do
    post(client, "/sharing/check_job_status", %{"async_job_id" => async_job_id})
  end

  @doc """
  Returns the status of an asynchronous member-removal job.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-check_remove_member_job_status
  """
  def check_remove_member_job_status(client, async_job_id) do
    post(client, "/sharing/check_remove_member_job_status", %{"async_job_id" => async_job_id})
  end

  @doc """
  Returns the status of an asynchronous share-folder job.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-check_share_job_status
  """
  def check_share_job_status(client, async_job_id) do
    post(client, "/sharing/check_share_job_status", %{"async_job_id" => async_job_id})
  end
end
