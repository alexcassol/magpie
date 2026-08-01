defmodule Magpie.Files.ListFolder do
  @moduledoc """
  """
  alias Magpie.Client
  import Magpie

  @doc """
  Starts returning the contents of a folder.

  ##Example

     Magpie.Files.ListFolder.list_folder client, "/path"

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-list_folder
  """
  @spec list_folder(Client.t(), binary) :: Magpie.response()
  def list_folder(client, path) do
    body = %{"path" => path}
    post(client, "/files/list_folder", body)
  end

  @doc """
  Once a cursor has been retrieved from list_folder,
  use this to paginate through all files and retrieve updates to the folder,
  following the same rules as documented for list_folder.

  ##Example

     Magpie.Files.ListFolder.list_folder_continue client, ""

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-list_folder-continue
  """
  @spec list_folder_continue(Client.t(), binary) :: Magpie.response()
  def list_folder_continue(client, cursor) do
    body = %{"cursor" => cursor}
    post(client, "/files/list_folder/continue", body)
  end

  @doc """
  Return revisions of a file.

  ##Example

     Magpie.Files.ListFolder.list_revisions client, ""

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-list_revisions
  """
  @spec list_revisions(Client.t(), binary, number) :: Magpie.response()
  def list_revisions(client, path, limit \\ 10) do
    body = %{"path" => path, "limit" => limit}
    post(client, "/files/list_revisions", body)
  end

  @doc """
  A way to quickly get a cursor for the folder's state.

  ##Example

     Magpie.Files.ListFolder.get_latest_cursor client, ""

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-list_revisions
  """
  @spec get_latest_cursor(Client.t(), binary) :: Magpie.response()
  def get_latest_cursor(client, path) do
    body = %{"path" => path}
    post(client, "/files/list_folder/get_latest_cursor", body)
  end

  @doc """
  A longpoll endpoint to wait for changes on an account.

  ##Example

     Magpie.Files.ListFolder.longpoll client, ""

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-list_folder-longpoll
  """
  @spec longpoll(Client.t(), binary) :: Magpie.response()
  def longpoll(client, cursor) do
    body = %{"cursor" => cursor, "timeout" => 30}
    post(client, "/files/list_folder/longpoll", body)
  end
end
