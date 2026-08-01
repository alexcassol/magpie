defmodule Magpie.Files do
  @moduledoc """
  This module contains endpoints and data types
  for basic file operations.
  """
  import Magpie
  import Magpie.Utils
  alias Magpie.Client
  alias Magpie.Files.UploadSession

  # Dropbox rejects single-request uploads above 150 MiB
  @session_threshold 150 * 1024 * 1024
  @default_chunk_size 8 * 1024 * 1024

  @doc """
  Create folder returns map

  ## Example

    Magpie.Files.create_folder client, "/Path"

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-create_folder
  """
  @spec create_folder(Client.t(), binary) :: any
  def create_folder(client, path) do
    body = %{"path" => path}
    post(client, "/files/create_folder_v2", body)
  end

  @doc """
  Same as `create_folder/2` but returns `{:ok, %Magpie.Folder{}}`.

  ## Example

    Magpie.Files.create_folder_to_struct client, "/Path"

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-create_folder
  """
  @spec create_folder_to_struct(Client.t(), binary) ::
          {:ok, Magpie.Folder.t()} | {:error, Magpie.Error.t()}
  def create_folder_to_struct(client, path) do
    case create_folder(client, path) do
      {:ok, response} -> {:ok, to_struct(%Magpie.Folder{}, response)}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Delete the file or folder at a given path.
  If the path is a folder, all its contents will be deleted too.
  A successful response indicates that the file or folder was deleted.
  The returned metadata will be the corresponding FileMetadata
  or FolderMetadata for the item at time of deletion, and not a DeletedMetadata object.

  ## Example

     Magpie.Files.delete_folder client, "/Homework/math/Prime_Numbers.txt"

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-delete_v2
  """
  def delete_folder(client, path) do
    body = %{"path" => path}
    post(client, "/files/delete_v2", body)
  end

  @doc """
  Same as `delete_folder/2` but returns `{:ok, %Magpie.Folder{}}`.

  ## Example

    Magpie.Files.delete_folder_to_struct client, "/Path"

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-delete_v2
  """
  @spec delete_folder_to_struct(Client.t(), binary) ::
          {:ok, Magpie.Folder.t()} | {:error, Magpie.Error.t()}
  def delete_folder_to_struct(client, path) do
    case delete_folder(client, path) do
      {:ok, response} -> {:ok, to_struct(%Magpie.Folder{}, response)}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Copy a file or folder to a different location in the user's Dropbox.
  If the source path is a folder all its contents will be copied.

  ## Example

    Magpie.Files.copy(client, "/Temp/first", "/Tmp/second")

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-copy_v2
  """
  def copy(client, from_path, to_path) do
    body = %{"from_path" => from_path, "to_path" => to_path}
    post(client, "/files/copy_v2", body)
  end

  @doc """
  Move a file or folder to a different location in the user's Dropbox.
  If the source path is a folder all its contents will be moved.

  ## Example

    Magpie.Files.move(client, "/Homework/math", "/Homework/algebra")

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-move_v2
  """
  def move(client, from_path, to_path) do
    body = %{"from_path" => from_path, "to_path" => to_path}
    post(client, "/files/move_v2", body)
  end

  @doc """
  Restore a file to a specific revision.

  ## Example

    Magpie.Files.restore(client, "/root/word.docx", "a1c10ce0dd78")

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-restore
  """
  def restore(client, path, rev) do
    body = %{"path" => path, "rev" => rev}
    post(client, "/files/restore", body)
  end

  @doc """
  Searches for files and folders.

  `options` accepts the `SearchOptions` fields, e.g.
  `%{"path" => "/Photos", "max_results" => 100, "filename_only" => true}`.

  ## Example

    Magpie.Files.search(client, "word.docx", %{"path" => "/root"})

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-search_v2
  """
  def search(client, query, options \\ %{}) do
    body = %{"query" => query, "options" => options}
    post(client, "/files/search_v2", body)
  end

  @doc """
  Fetches the next page of search results returned from `search/3`.

  ## Example

    Magpie.Files.search_continue(client, cursor)

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-search-continue_v2
  """
  def search_continue(client, cursor) do
    body = %{"cursor" => cursor}
    post(client, "/files/search/continue_v2", body)
  end

  @doc """
  Returns a lazy `Stream` over **all** search matches, fetching pages
  through `search/3` + `search_continue/2` on demand. Raises
  `Magpie.Error` if a page request fails.

  ## Example

      client
      |> Magpie.Files.search_stream("report", %{"path" => "/Work"})
      |> Enum.take(50)

  """
  def search_stream(client, query, options \\ %{}) do
    Magpie.Pager.stream(
      fn -> search(client, query, options) end,
      fn cursor -> search_continue(client, cursor) end,
      items_key: "matches"
    )
  end

  @doc """
  Create a new file with the contents provided in the request.

  ## Example

    Magpie.Files.upload client, "/mypdf.pdf", "/mypdf.pdf"

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-upload
  """
  def upload(client, path, file, mode \\ "add", autorename \\ true, mute \\ false) do
    dropbox_headers = %{
      :path => path,
      :mode => mode,
      :autorename => autorename,
      :mute => mute
    }

    headers = %{
      "Dropbox-API-Arg" => Jason.encode!(dropbox_headers),
      "Content-Type" => "application/octet-stream"
    }

    upload_request(
      client,
      upload_url(),
      "files/upload",
      file,
      headers
    )
  end

  @doc """
  Uploads the local file at `local_path` to `path` in the user's Dropbox,
  picking the right strategy automatically:

    * files up to `:session_threshold` bytes go through a single
      `/files/upload` call;
    * larger files are streamed through an upload session
      (`start` → `append_v2` × N → `finish`) in chunks of `:chunk_size`
      bytes, without ever loading the whole file into memory.

  Returns `{:ok, file_metadata}` on success, `{:error, %Magpie.Error{}}` on
  Dropbox errors, or `{:error, posix}` when the local file cannot be read.

  ## Options

    * `:chunk_size` — upload session chunk size in bytes (default 8 MiB)
    * `:session_threshold` — size above which an upload session is used
      (default 150 MiB, the Dropbox limit for single-request uploads)
    * `:mode` — `"add"` (default) or `"overwrite"`
    * `:autorename` — default `true`
    * `:mute` — default `false`

  ## Example

      {:ok, metadata} = Magpie.Files.upload_file(client, "/Backup/db.dump", "priv/db.dump")

  """
  def upload_file(client, path, local_path, opts \\ []) do
    threshold = Keyword.get(opts, :session_threshold, @session_threshold)

    case File.stat(local_path) do
      {:ok, %File.Stat{size: size}} when size <= threshold ->
        upload(
          client,
          path,
          local_path,
          Keyword.get(opts, :mode, "add"),
          Keyword.get(opts, :autorename, true),
          Keyword.get(opts, :mute, false)
        )

      {:ok, %File.Stat{}} ->
        upload_via_session(client, path, local_path, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upload_via_session(client, path, local_path, opts) do
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)

    commit = %{
      "path" => path,
      "mode" => Keyword.get(opts, :mode, "add"),
      "autorename" => Keyword.get(opts, :autorename, true),
      "mute" => Keyword.get(opts, :mute, false)
    }

    with {:ok, %{"session_id" => session_id}} <- UploadSession.start_data(client, "") do
      local_path
      |> File.stream!(chunk_size)
      |> Enum.reduce_while({:ok, 0}, fn chunk, {:ok, offset} ->
        case UploadSession.append_data(client, session_id, offset, chunk) do
          {:ok, _} -> {:cont, {:ok, offset + byte_size(chunk)}}
          error -> {:halt, error}
        end
      end)
      |> finish_session(client, session_id, commit)
    end
  end

  defp finish_session({:ok, offset}, client, session_id, commit),
    do: UploadSession.finish_data(client, session_id, offset, commit)

  defp finish_session(error, _client, _session_id, _commit), do: error

  @doc """
  Download a file from a user's Dropbox.

  ## Example

    Magpie.Files.download client, "/mypdf.pdf"

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-download
  """
  def download(client, path) do
    dropbox_headers = %{
      :path => path
    }

    headers = %{"Dropbox-API-Arg" => Jason.encode!(dropbox_headers)}

    download_request(
      client,
      upload_url(),
      "files/download",
      [],
      headers
    )
  end

  @doc """
  Get a thumbnail for an image.

  ## Example

    Magpie.Files.get_thumbnail client, "/image.jpg"

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-get_thumbnail
  """
  def get_thumbnail(client, path, format \\ "jpeg", size \\ "w64h64") do
    dropbox_headers = %{
      :path => path,
      :format => format,
      :size => size
    }

    headers = %{"Dropbox-API-Arg" => Jason.encode!(dropbox_headers)}

    download_request(
      client,
      upload_url(),
      "files/get_thumbnail",
      [],
      headers
    )
  end

  @doc """
  Get thumbnails for a list of images. We allow up to 25 thumbnails in a single batch.

  ## Example
    batch = %{ "path" => "/image.jpg", "format" => "jpeg", "size" => "w64h64"}
    entries = [batch]
    Magpie.Files.get_thumbnail_batch client, entries

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-get_thumbnail_batch
  """
  def get_thumbnail_batch(client, entries) do
    body = %{"entries" => entries}

    post_url(
      client,
      upload_url(),
      "/files/get_thumbnail_batch",
      body
    )
  end

  @doc """
  Get a preview for a file.

  ## Example

    Magpie.Files.get_preview client, "/mypdf.pdf"

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-get_preview
  """
  def get_preview(client, path) do
    dropbox_headers = %{
      :path => path
    }

    headers = %{"Dropbox-API-Arg" => Jason.encode!(dropbox_headers)}

    download_request(
      client,
      upload_url(),
      "files/get_preview",
      [],
      headers
    )
  end

  @doc """
  Get a temporary link to stream content of a file. This link will expire in four hours and afterwards you will get 410 Gone. Content-Type of the link is determined automatically by the file's mime type.

  ## Example

    Magpie.Files.get_temporary_link client, "/video.mp4"

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-get_preview
  """
  def get_temporary_link(client, path) do
    body = %{"path" => path}
    post(client, "/files/get_temporary_link", body)
  end

  @doc """
  Permanently delete the file or folder at a given path. Requires a Dropbox
  Business account with Advanced or Enterprise plan. `opts` accepts
  `"parent_rev"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-permanently_delete
  """
  def permanently_delete(client, path, opts \\ %{}) do
    body = Map.merge(%{"path" => path}, opts)
    post(client, "/files/permanently_delete", body)
  end

  @doc """
  Get a one-time-use temporary upload link for a direct binary upload.
  `commit_info` takes the `/files/upload` argument fields, e.g.
  `%{"path" => "/a.txt", "mode" => "add"}`; `duration` is in seconds.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-get_temporary_upload_link
  """
  def get_temporary_upload_link(client, commit_info, duration \\ 14_400) do
    body = %{"commit_info" => commit_info, "duration" => duration}
    post(client, "/files/get_temporary_upload_link", body)
  end

  @doc """
  Download a folder from the user's Dropbox as a zip file.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-download_zip
  """
  def download_zip(client, path) do
    headers = %{"Dropbox-API-Arg" => Jason.encode!(%{"path" => path})}
    download_request(client, upload_url(), "files/download_zip", [], headers)
  end

  @doc """
  Export a file from the user's Dropbox to a portable format (for files that
  cannot be downloaded directly, e.g. Paper docs). `opts` accepts
  `"export_format"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-export
  """
  def export(client, path, opts \\ %{}) do
    arg = Map.merge(%{"path" => path}, opts)
    headers = %{"Dropbox-API-Arg" => Jason.encode!(arg)}
    download_request(client, upload_url(), "files/export", [], headers)
  end

  @doc """
  Get a thumbnail for an image or document, addressed by path or shared link.
  `resource` is `%{".tag" => "path", "path" => ...}` or
  `%{".tag" => "link", "url" => ...}`; `opts` accepts `"format"`, `"size"`,
  `"mode"` and `"quality"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-get_thumbnail_v2
  """
  def get_thumbnail_v2(client, resource, opts \\ %{}) do
    arg = Map.merge(%{"resource" => resource}, opts)
    headers = %{"Dropbox-API-Arg" => Jason.encode!(arg)}
    download_request(client, upload_url(), "files/get_thumbnail_v2", [], headers)
  end

  @doc """
  Returns the metadata for a file or folder.

  ## Example

    Magpie.Files.get_metadata client, "/mypdf.pdf"

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-get_metadata
  """
  def get_metadata(
        client,
        path,
        include_media_info \\ false,
        include_deleted \\ false,
        include_has_explicit_shared_members \\ false
      ) do
    body = %{
      "path" => path,
      "include_media_info" => include_media_info,
      "include_deleted" => include_deleted,
      "include_has_explicit_shared_members" => include_has_explicit_shared_members
    }

    post(client, "/files/get_metadata", body)
  end
end
