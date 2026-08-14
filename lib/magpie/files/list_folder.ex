defmodule Magpie.Files.ListFolder do
  @moduledoc """
  Folder listing and change-cursor endpoints (`/files/list_folder*`).
  """
  alias Magpie.Client
  import Magpie

  @doc """
  Starts returning the contents of a folder. `opts` accepts the other
  `/files/list_folder` argument fields, e.g. `"recursive"`, `"limit"`,
  `"include_deleted"` and `"include_restorable_info"`.

  ##Example

     Magpie.Files.ListFolder.list_folder client, "/path"

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-list_folder
  """
  @spec list_folder(Client.t(), binary, map) :: Magpie.response()
  def list_folder(client, path, opts \\ %{}) do
    body = Map.merge(%{"path" => path}, opts)
    post(client, "/files/list_folder", body)
  end

  @doc """
  Returns a lazy `Stream` over **all** entries of a folder, fetching pages
  through `list_folder/2` + `list_folder_continue/2` on demand — no cursor
  handling needed. Raises `Magpie.Error` if a page request fails.

  ## Example

      client
      |> Magpie.Files.ListFolder.stream("/Photos")
      |> Stream.filter(&(&1[".tag"] == "file"))
      |> Enum.map(& &1["name"])

  """
  def stream(client, path, opts \\ %{}) do
    Magpie.Pager.stream(
      fn -> list_folder(client, path, opts) end,
      fn cursor -> list_folder_continue(client, cursor) end
    )
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
  Return revisions of a file. `opts` accepts the other `/files/list_revisions`
  argument fields, e.g. `"mode"`, `"before_rev"` and `"include_restorable_info"`.

  ##Example

     Magpie.Files.ListFolder.list_revisions client, ""

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-list_revisions
  """
  @spec list_revisions(Client.t(), binary, number, map) :: Magpie.response()
  def list_revisions(client, path, limit \\ 10, opts \\ %{}) do
    body = Map.merge(%{"path" => path, "limit" => limit}, opts)
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
