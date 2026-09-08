defmodule Magpie.Files do
  @moduledoc """
  Basic file operations (`/files/*`).

  Functions that return the metadata of a file or folder hand back
  `Magpie.FileMetadata`, `Magpie.FolderMetadata` or `Magpie.DeletedMetadata`
  structs — see `Magpie.Metadata` — instead of raw JSON maps. Endpoints that
  wrap the metadata in a result object (`create_folder/2`, `delete_folder/2`,
  `copy/3`, `move/3`) are unwrapped, so the struct is the whole result.
  """
  import Magpie
  import Magpie.Utils
  alias Magpie.Client
  alias Magpie.ContentHash
  alias Magpie.IntegrityError
  alias Magpie.Files.UploadSession
  alias Magpie.Metadata

  # Dropbox rejects single-request uploads above 150 MiB
  @session_threshold 150 * 1024 * 1024
  @default_chunk_size 8 * 1024 * 1024

  @doc """
  Create a folder at a given path. Returns the new folder's
  `Magpie.FolderMetadata`.

  ## Example

      {:ok, %Magpie.FolderMetadata{id: "id:" <> _}} = Magpie.Files.create_folder(client, "/Path")

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-create_folder
  """
  @spec create_folder(Client.t(), binary) ::
          {:ok, Magpie.FolderMetadata.t()} | {:error, Magpie.Error.t()}
  def create_folder(client, path) do
    body = %{"path" => path}

    client
    |> post("/files/create_folder_v2", body)
    |> Metadata.map_ok(&Metadata.unwrap(&1, :folder))
  end

  @doc """
  Same as `create_folder/2` but returns `{:ok, %Magpie.Folder{}}`.

  Deprecated: `create_folder/2` itself returns a typed
  `Magpie.FolderMetadata` since 0.4.0.
  """
  @deprecated "create_folder/2 now returns a Magpie.FolderMetadata struct"
  @spec create_folder_to_struct(Client.t(), binary) ::
          {:ok, Magpie.Folder.t()} | {:error, Magpie.Error.t()}
  def create_folder_to_struct(client, path) do
    case create_folder(client, path) do
      {:ok, metadata} -> {:ok, legacy_folder(metadata)}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Delete the file or folder at a given path.
  If the path is a folder, all its contents will be deleted too.
  A successful response indicates that the file or folder was deleted.
  The returned metadata will be the corresponding FileMetadata
  or FolderMetadata for the item at time of deletion, and not a DeletedMetadata object.

  Returns the `Magpie.FileMetadata` or `Magpie.FolderMetadata` of the
  deleted item. `opts` accepts Dropbox's optional `"parent_rev"` field.

  ## Example

      {:ok, %Magpie.FileMetadata{}} =
        Magpie.Files.delete_folder(client, "/Homework/math/Prime_Numbers.txt")

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-delete_v2
  """
  @spec delete_folder(Client.t(), binary, map) ::
          {:ok, Magpie.FileMetadata.t() | Magpie.FolderMetadata.t()}
          | {:error, Magpie.Error.t()}
  def delete_folder(client, path, opts \\ %{}) do
    body = Map.merge(%{"path" => path}, opts)

    client
    |> post("/files/delete_v2", body)
    |> Metadata.map_ok(&Metadata.unwrap/1)
  end

  @doc """
  Same as `delete_folder/2` but returns `{:ok, %Magpie.Folder{}}`.

  Deprecated: `delete_folder/2` itself returns typed metadata since 0.4.0.
  """
  @deprecated "delete_folder/2 now returns a Magpie.FileMetadata or Magpie.FolderMetadata struct"
  @spec delete_folder_to_struct(Client.t(), binary) ::
          {:ok, Magpie.Folder.t()} | {:error, Magpie.Error.t()}
  def delete_folder_to_struct(client, path) do
    case delete_folder(client, path) do
      {:ok, metadata} -> {:ok, legacy_folder(metadata)}
      {:error, error} -> {:error, error}
    end
  end

  # The legacy `Magpie.Folder` carries a subset of the typed metadata fields.
  defp legacy_folder(%{name: name, id: id, path_display: path_display, path_lower: path_lower}),
    do: %Magpie.Folder{id: id, name: name, path_display: path_display, path_lower: path_lower}

  defp legacy_folder(other) when is_map(other), do: to_struct(%Magpie.Folder{}, other)

  @doc """
  Copy a file or folder to a different location in the user's Dropbox.
  If the source path is a folder all its contents will be copied.

  Returns the metadata of the copy.

  ## Example

      {:ok, %Magpie.FileMetadata{path_display: "/Tmp/second"}} =
        Magpie.Files.copy(client, "/Temp/first", "/Tmp/second")

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-copy_v2
  """
  @spec copy(Client.t(), binary, binary) ::
          {:ok, Magpie.FileMetadata.t() | Magpie.FolderMetadata.t()}
          | {:error, Magpie.Error.t()}
  def copy(client, from_path, to_path) do
    body = %{"from_path" => from_path, "to_path" => to_path}

    client
    |> post("/files/copy_v2", body)
    |> Metadata.map_ok(&Metadata.unwrap/1)
  end

  @doc """
  Move a file or folder to a different location in the user's Dropbox.
  If the source path is a folder all its contents will be moved.

  Returns the metadata at the new location.

  ## Example

      {:ok, %Magpie.FolderMetadata{name: "algebra"}} =
        Magpie.Files.move(client, "/Homework/math", "/Homework/algebra")

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-move_v2
  """
  @spec move(Client.t(), binary, binary) ::
          {:ok, Magpie.FileMetadata.t() | Magpie.FolderMetadata.t()}
          | {:error, Magpie.Error.t()}
  def move(client, from_path, to_path) do
    body = %{"from_path" => from_path, "to_path" => to_path}

    client
    |> post("/files/move_v2", body)
    |> Metadata.map_ok(&Metadata.unwrap/1)
  end

  @doc """
  Restore a file to a specific revision. Returns the restored file's
  `Magpie.FileMetadata`.

  ## Example

      {:ok, %Magpie.FileMetadata{rev: rev}} =
        Magpie.Files.restore(client, "/root/word.docx", "a1c10ce0dd78")

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-restore
  """
  @spec restore(Client.t(), binary, binary) ::
          {:ok, Magpie.FileMetadata.t()} | {:error, Magpie.Error.t()}
  def restore(client, path, rev) do
    body = %{"path" => path, "rev" => rev}

    client
    |> post("/files/restore", body)
    |> Metadata.map_ok(&Metadata.decode(&1, :file))
  end

  @doc """
  Searches for files and folders.

  `options` accepts the `SearchOptions` fields, e.g.
  `%{"path" => "/Photos", "max_results" => 100, "filename_only" => true}`.

  Each match's `"metadata"` is decoded into a `Magpie.FileMetadata` /
  `Magpie.FolderMetadata` struct (see `Magpie.Metadata.decode_matches/1`);
  the rest of the match (`"match_type"`, `"highlights"`) is kept as is.

  ## Example

      {:ok, %{"matches" => [%{"metadata" => %Magpie.FileMetadata{}} | _]}} =
        Magpie.Files.search(client, "word.docx", %{"path" => "/root"})

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-search_v2
  """
  def search(client, query, options \\ %{}) do
    body = %{"query" => query, "options" => options}

    client
    |> post("/files/search_v2", body)
    |> Metadata.map_ok(&Metadata.decode_matches/1)
  end

  @doc """
  Fetches the next page of search results returned from `search/3`.

  ## Example

    Magpie.Files.search_continue(client, cursor)

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-search-continue_v2
  """
  def search_continue(client, cursor) do
    body = %{"cursor" => cursor}

    client
    |> post("/files/search/continue_v2", body)
    |> Metadata.map_ok(&Metadata.decode_matches/1)
  end

  @doc """
  Returns a lazy `Stream` over **all** search matches, fetching pages
  through `search/3` + `search_continue/2` on demand. Raises
  `Magpie.Error` if a page request fails.

  ## Example

      client
      |> Magpie.Files.search_stream("report", %{"path" => "/Work"})
      |> Enum.take(50)
      |> Enum.map(fn %{"metadata" => %Magpie.FileMetadata{} = file} -> file.path_display end)

  """
  def search_stream(client, query, options \\ %{}) do
    Magpie.Pager.stream(
      fn -> search(client, query, options) end,
      fn cursor -> search_continue(client, cursor) end,
      items_key: "matches"
    )
  end

  @doc """
  Create a new file with the contents of the local file at `file`. Returns
  the `Magpie.FileMetadata` of the uploaded file.

  ## Example

      {:ok, %Magpie.FileMetadata{content_hash: hash}} =
        Magpie.Files.upload(client, "/mypdf.pdf", "/mypdf.pdf")

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

    client
    |> upload_request(upload_url(), "files/upload", file, headers)
    |> Metadata.map_ok(&Metadata.decode(&1, :file))
  end

  @doc """
  Uploads the local file at `local_path` to `path` in the user's Dropbox,
  picking the right strategy automatically:

    * files up to `:session_threshold` bytes go through a single
      `/files/upload` call;
    * larger files are streamed through an upload session
      (`start` → `append_v2` × N → `finish`) in chunks of `:chunk_size`
      bytes, without ever loading the whole file into memory.

  Returns `{:ok, %Magpie.FileMetadata{}}` on success, `{:error, %Magpie.Error{}}`
  on Dropbox errors, or `{:error, posix}` when the local file cannot be read.

  ## Options

    * `:chunk_size` — upload session chunk size in bytes (default 8 MiB)
    * `:session_threshold` — size above which an upload session is used
      (default 150 MiB, the Dropbox limit for single-request uploads)
    * `:mode` — `"add"` (default) or `"overwrite"`
    * `:autorename` — default `true`
    * `:mute` — default `false`

  ## Example

      {:ok, %Magpie.FileMetadata{size: size, content_hash: hash}} =
        Magpie.Files.upload_file(client, "/Backup/db.dump", "priv/db.dump")

  """
  def upload_file(client, path, local_path, opts \\ []) do
    opts = Keyword.put(opts, :transfer_path, path)
    threshold = Keyword.get(opts, :session_threshold, @session_threshold)

    case File.stat(local_path) do
      {:ok, %File.Stat{size: size}} when size <= threshold ->
        opts = Keyword.put(opts, :transfer_size, size)

        upload(
          client,
          path,
          local_path,
          write_mode(opts),
          Keyword.get(opts, :autorename, true),
          Keyword.get(opts, :mute, false)
        )
        |> notify_upload_progress(opts, size)
        |> verify_known_hash(path, opts, fn ->
          Metadata.content_hash(File.stream!(local_path, 65_536))
        end)

      {:ok, %File.Stat{size: size}} ->
        opts = Keyword.put(opts, :transfer_size, size)
        upload_via_session(client, path, File.stream!(local_path, chunk_size(opts)), opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Uploads binary or iodata content, selecting a single request or an upload
  session from its byte size. For an enumerable whose size is not known in
  advance, use `upload_stream/4`.
  """
  @spec upload_data(Client.t(), binary(), iodata(), keyword()) ::
          {:ok, Magpie.FileMetadata.t()} | {:error, Magpie.Error.t()}
  def upload_data(client, path, data, opts \\ []) do
    opts = Keyword.put(opts, :transfer_path, path)
    threshold = Keyword.get(opts, :session_threshold, @session_threshold)
    size = IO.iodata_length(data)
    opts = Keyword.put(opts, :transfer_size, size)

    if size <= threshold do
      upload_data_once(client, path, data, opts)
      |> notify_upload_progress(opts, size)
      |> verify_known_hash(path, opts, fn -> Metadata.content_hash(IO.iodata_to_binary(data)) end)
    else
      upload_via_session(
        client,
        path,
        binary_chunks(IO.iodata_to_binary(data), chunk_size(opts)),
        opts
      )
    end
  end

  @doc """
  Streams an enumerable of binary or iodata chunks into a Dropbox upload
  session. Chunks from the enumerable may have any size; Magpie buffers at
  most one configured upload chunk and sends the final partial chunk with
  the commit request.
  """
  @spec upload_stream(Client.t(), binary(), Enumerable.t(), keyword()) ::
          {:ok, Magpie.FileMetadata.t()} | {:error, Magpie.Error.t()}
  def upload_stream(client, path, enumerable, opts \\ []) do
    opts = Keyword.put(opts, :transfer_path, path)
    upload_via_session(client, path, enumerable, opts)
  end

  defp upload_data_once(client, path, data, opts) do
    headers = %{
      "Dropbox-API-Arg" => Jason.encode!(commit(path, opts)),
      "Content-Type" => "application/octet-stream"
    }

    client
    |> upload_data_request(upload_url(), "files/upload", data, headers)
    |> Metadata.map_ok(&Metadata.decode(&1, :file))
  end

  defp upload_via_session(client, path, enumerable, opts) do
    chunk_size = chunk_size(opts)
    commit = commit(path, opts)
    hash_state = if Keyword.get(opts, :verify, false), do: ContentHash.new(), else: nil

    with {:ok, %{"session_id" => session_id}} <- UploadSession.start_data(client, "") do
      enumerable
      |> Enum.reduce_while({:ok, 0, <<>>, hash_state}, fn piece,
                                                          {:ok, offset, buffer, hash_state} ->
        piece = chunk_to_binary(piece)
        data = buffer <> piece
        {chunks, rest} = split_full_chunks(data, chunk_size)
        hash_state = update_hash(hash_state, piece)

        case append_chunks(chunks, client, session_id, offset, opts) do
          {:ok, next_offset} -> {:cont, {:ok, next_offset, rest, hash_state}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> finish_session(client, session_id, commit, path, opts)
    end
  end

  defp finish_session({:ok, offset, tail, hash_state}, client, session_id, commit, path, opts) do
    result = UploadSession.finish_data(client, session_id, offset, commit, tail)
    transferred = offset + byte_size(tail)

    result
    |> notify_upload_progress(opts, transferred)
    |> verify_hash(path, opts, hash_state)
  end

  defp finish_session(error, _client, _session_id, _commit, _path, _opts), do: error

  defp append_chunks(chunks, client, session_id, offset, opts) do
    Enum.reduce_while(chunks, {:ok, offset}, fn chunk, {:ok, current_offset} ->
      case UploadSession.append_data(client, session_id, current_offset, chunk) do
        {:ok, _} ->
          next_offset = current_offset + byte_size(chunk)
          notify_progress(opts, next_offset)
          {:cont, {:ok, next_offset}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp split_full_chunks(data, chunk_size), do: split_full_chunks(data, chunk_size, [])

  defp split_full_chunks(data, chunk_size, chunks) when byte_size(data) >= chunk_size do
    <<chunk::binary-size(^chunk_size), rest::binary>> = data
    split_full_chunks(rest, chunk_size, [chunk | chunks])
  end

  defp split_full_chunks(rest, _chunk_size, chunks), do: {Enum.reverse(chunks), rest}

  defp binary_chunks(binary, chunk_size) do
    Stream.unfold(binary, fn
      <<>> -> nil
      data when byte_size(data) <= chunk_size -> {data, <<>>}
      <<chunk::binary-size(^chunk_size), rest::binary>> -> {chunk, rest}
    end)
  end

  defp chunk_to_binary(piece) when is_integer(piece) and piece in 0..255, do: <<piece>>
  defp chunk_to_binary(piece), do: IO.iodata_to_binary(piece)

  defp chunk_size(opts) do
    case Keyword.get(opts, :chunk_size, @default_chunk_size) do
      size when is_integer(size) and size > 0 -> size
      size -> raise ArgumentError, ":chunk_size must be a positive integer, got: #{inspect(size)}"
    end
  end

  defp commit(path, opts) do
    %{
      "path" => path,
      "mode" => write_mode(opts),
      "autorename" => Keyword.get(opts, :autorename, true),
      "mute" => Keyword.get(opts, :mute, false)
    }
  end

  defp write_mode(opts) do
    case Keyword.fetch(opts, :if_rev) do
      {:ok, rev} when is_binary(rev) -> %{".tag" => "update", "update" => rev}
      {:ok, rev} -> raise ArgumentError, ":if_rev must be a revision string, got: #{inspect(rev)}"
      :error -> Keyword.get(opts, :mode, "add")
    end
  end

  defp update_hash(nil, _piece), do: nil
  defp update_hash(state, piece), do: ContentHash.update(state, piece)

  defp verify_known_hash(result, path, opts, hash_fun) do
    if Keyword.get(opts, :verify, false) do
      expected = Keyword.get_lazy(opts, :expected_hash, hash_fun)
      compare_hash(result, path, expected)
    else
      result
    end
  end

  defp verify_hash(result, path, opts, hash_state) do
    if Keyword.get(opts, :verify, false) do
      expected = Keyword.get(opts, :expected_hash) || ContentHash.finalize(hash_state)
      compare_hash(result, path, expected)
    else
      result
    end
  end

  defp compare_hash(
         {:ok, %Magpie.FileMetadata{content_hash: expected}} = result,
         _path,
         expected
       ),
       do: result

  defp compare_hash({:ok, %Magpie.FileMetadata{content_hash: actual}}, path, expected),
    do: {:error, %IntegrityError{path: path, expected: expected, actual: actual}}

  defp compare_hash(result, _path, _expected), do: result

  defp notify_upload_progress({:ok, _} = result, opts, transferred) do
    notify_progress(opts, transferred)
    result
  end

  defp notify_upload_progress(result, _opts, _transferred), do: result

  defp notify_progress(opts, transferred) do
    total = Keyword.get(opts, :transfer_size)

    :telemetry.execute(
      [:magpie, :transfer, :progress],
      %{transferred: transferred, total: total},
      %{direction: :upload, path: Keyword.get(opts, :transfer_path)}
    )

    case Keyword.get(opts, :progress) do
      nil ->
        :ok

      callback when is_function(callback, 2) ->
        callback.(transferred, total)

      callback ->
        raise ArgumentError,
              ":progress must be a two-argument function, got: #{inspect(callback)}"
    end
  end

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
  Streams a Dropbox file directly to `destination` without loading it into
  BEAM memory. The destination is replaced only after a successful response.

  Returns `{:ok, %{path: destination, headers: headers}}`, a normalized
  Dropbox API error, or `{:error, posix}` for a local filesystem error.
  """
  @spec download_file(Client.t(), binary(), Path.t(), keyword()) ::
          {:ok, %{path: Path.t(), headers: list() | map()}}
          | {:error, Magpie.Error.t() | File.posix()}
  def download_file(client, path, destination, opts \\ []) do
    headers = %{"Dropbox-API-Arg" => Jason.encode!(%{"path" => path})}
    opts = Keyword.put(opts, :transfer_path, path)

    download_file_request(
      client,
      upload_url(),
      "files/download",
      [],
      headers,
      destination,
      opts
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
  `%{".tag" => "link", "url" => ...}`; `opts` accepts `"format"`, `"size"`
  and `"mode"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-get_thumbnail_v2
  """
  def get_thumbnail_v2(client, resource, opts \\ %{}) do
    arg = Map.merge(%{"resource" => resource}, opts)
    headers = %{"Dropbox-API-Arg" => Jason.encode!(arg)}
    download_request(client, upload_url(), "files/get_thumbnail_v2", [], headers)
  end

  @doc """
  Returns the metadata for a file or folder as a `Magpie.FileMetadata`,
  `Magpie.FolderMetadata` or — with `include_deleted` — `Magpie.DeletedMetadata`.

  ## Example

      {:ok, %Magpie.FileMetadata{size: size, server_modified: %DateTime{}}} =
        Magpie.Files.get_metadata(client, "/mypdf.pdf")

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-get_metadata
  """
  @spec get_metadata(Client.t(), binary, boolean, boolean, boolean) ::
          {:ok, Magpie.Metadata.t()} | {:error, Magpie.Error.t()}
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

    client
    |> post("/files/get_metadata", body)
    |> Metadata.map_ok(&Metadata.decode/1)
  end
end
