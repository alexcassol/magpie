defmodule Magpie.Storage do
  @moduledoc """
  A small object-storage-style API backed by Dropbox.

  `Storage` is the convenient entry point for common application operations;
  `Magpie.Files` remains available when Dropbox-specific controls are needed.

      alias Magpie.Storage

      {:ok, %Magpie.FileMetadata{}} =
        Storage.put(client, "/reports/today.json", {:binary, ~s({"ok":true})})

      {:ok, contents} = Storage.get(client, "/reports/today.json")
      {:ok, "/tmp/today.json"} =
        Storage.download(client, "/reports/today.json", "/tmp/today.json")

  Upload sources are explicit:

    * `{:file, path}` streams a local file and automatically selects a single
      request or an upload session from its size;
    * `{:binary, iodata}` uploads in-memory content and makes the same choice;
    * `{:stream, enumerable}` always uses an upload session, buffering no more
      than one configured chunk between requests.

  Paths are Dropbox paths, not S3 bucket/key pairs. Temporary download URLs
  expire according to Dropbox's rules (normally after four hours).
  """

  alias Magpie.Error
  alias Magpie.Files
  alias Magpie.Files.ListFolder
  alias Magpie.Metadata

  @type source :: {:file, Path.t()} | {:binary, iodata()} | {:stream, Enumerable.t()}
  @type result(value) :: {:ok, value} | {:error, Exception.t() | File.posix()}

  @batch_options [:max_concurrency, :timeout, :on_progress]

  @doc """
  Uploads a file, binary/iodata value, or stream to `key`.

  Options are `:mode`, `:if_rev`, `:autorename`, `:mute`, `:chunk_size`,
  `:session_threshold`, `:verify`, `:skip_unchanged` and `:progress`.
  `:if_rev` performs a conditional update, `:verify` compares Dropbox's
  content hash after upload, and `:skip_unchanged` avoids uploading matching
  file/binary sources. Progress callbacks receive `(transferred, total)`;
  `total` can be `nil` for streams.
  """
  @spec put(Magpie.Client.t(), binary(), source(), keyword()) ::
          result(Magpie.FileMetadata.t())
          | {:ok, :unchanged, Magpie.FileMetadata.t()}
  def put(client, key, source, opts \\ []) do
    validate_progress!(opts)
    safely(fn -> do_put(client, key, source, opts) end)
  end

  defp do_put(client, key, {:file, path} = source, opts) do
    put_with_hash(client, key, source, opts, fn ->
      Metadata.content_hash(File.stream!(path, 65_536))
    end)
  end

  defp do_put(client, key, {:binary, data} = source, opts) do
    put_with_hash(client, key, source, opts, fn ->
      data |> IO.iodata_to_binary() |> Metadata.content_hash()
    end)
  end

  defp do_put(client, key, {:stream, enumerable}, opts) do
    if Keyword.get(opts, :skip_unchanged, false) do
      raise ArgumentError,
            ":skip_unchanged is not supported for streams because they cannot be read twice"
    end

    Files.upload_stream(client, key, enumerable, opts)
  end

  defp do_put(_client, _key, source, _opts) do
    raise ArgumentError,
          "expected source to be {:file, path}, {:binary, iodata}, or {:stream, enumerable}, got: #{inspect(source)}"
  end

  @doc """
  Like `put/4`, but raises on failure.

  Returns metadata directly after an upload, or `{:unchanged, metadata}` when
  `skip_unchanged: true` finds identical remote content.
  """
  def put!(client, key, source, opts \\ []), do: put(client, key, source, opts) |> unwrap!()

  @doc """
  Downloads `key` into memory and returns its bytes.

  Pass `with_headers: true` to retain the `%{body: body, headers: headers}`
  response shape used by `Magpie.Files.download/2`.
  """
  @spec get(Magpie.Client.t(), binary(), keyword()) :: result(binary() | map())
  def get(client, key, opts \\ []) do
    safely(fn ->
      case Files.download(client, key) do
        {:ok, %{body: body} = response} ->
          if Keyword.get(opts, :with_headers, false), do: {:ok, response}, else: {:ok, body}

        {:error, _} = error ->
          error
      end
    end)
  end

  @doc "Like `get/3`, but returns the bytes directly and raises on failure."
  def get!(client, key, opts \\ []), do: get(client, key, opts) |> unwrap!()

  @doc """
  Streams `key` to a local destination and returns that destination.

  The destination's parent must exist unless `mkdir_p: true` is passed.
  An existing destination is replaced only after Dropbox successfully sends
  the complete response. A `:progress` callback receives
  `(transferred, total)` as bytes arrive; pass the expected byte count as
  `:size` when it is known, otherwise `total` is `nil`.
  """
  @spec download(Magpie.Client.t(), binary(), Path.t(), keyword()) :: result(Path.t())
  def download(client, key, destination, opts \\ []) do
    validate_progress!(opts)

    safely(fn ->
      with :ok <- maybe_create_parent(destination, opts),
           {:ok, %{path: path}} <- Files.download_file(client, key, destination, opts) do
        {:ok, path}
      end
    end)
  end

  @doc "Like `download/4`, but returns the destination directly and raises on failure."
  def download!(client, key, destination, opts \\ []),
    do: download(client, key, destination, opts) |> unwrap!()

  @doc "Deletes a Dropbox file or folder and returns its final metadata."
  def delete(client, key, opts \\ []) do
    safely(fn -> Files.delete_folder(client, key, option_map(opts, [:parent_rev])) end)
  end

  @doc "Like `delete/3`, but returns metadata directly and raises on failure."
  def delete!(client, key, opts \\ []), do: delete(client, key, opts) |> unwrap!()

  @doc "Returns `true`, `false` for a missing key, or an error tuple for other failures."
  @spec exists?(Magpie.Client.t(), binary(), keyword()) :: boolean() | {:error, Exception.t()}
  def exists?(client, key, opts \\ []) do
    case stat(client, key, opts) do
      {:ok, _metadata} -> true
      {:error, %Error{} = error} -> if Error.not_found?(error), do: false, else: {:error, error}
      {:error, _} = error -> error
    end
  end

  @doc "Returns typed Dropbox metadata for `key`."
  def stat(client, key, opts \\ []) do
    safely(fn ->
      Files.get_metadata(
        client,
        key,
        Keyword.get(opts, :include_media_info, false),
        Keyword.get(opts, :include_deleted, false),
        Keyword.get(opts, :include_has_explicit_shared_members, false)
      )
    end)
  end

  @doc "Like `stat/3`, but returns metadata directly and raises on failure."
  def stat!(client, key, opts \\ []), do: stat(client, key, opts) |> unwrap!()

  @doc """
  Returns all entries below `prefix`, following every cursor page.

  Unlike the lazy `stream/3`, this eager convenience returns Dropbox API and
  Req transport failures as `{:error, exception}`. This lets background jobs
  handle a failed listing without crashing the worker.
  """
  @spec list(Magpie.Client.t(), binary(), keyword()) ::
          {:ok, [Magpie.Metadata.t()]} | {:error, Exception.t()}
  def list(client, prefix \\ "", opts \\ []) do
    safely(fn -> {:ok, client |> stream(prefix, opts) |> Enum.to_list()} end)
  end

  @doc "Like `list/3`, but returns entries directly and raises on failure."
  def list!(client, prefix \\ "", opts \\ []), do: list(client, prefix, opts) |> unwrap!()

  @doc "Returns a lazy stream over every entry below `prefix`."
  @spec stream(Magpie.Client.t(), binary(), keyword()) :: Enumerable.t()
  def stream(client, prefix \\ "", opts \\ []) do
    ListFolder.stream(client, prefix, option_map(opts))
  end

  @doc "Returns a temporary direct-download URL for `key`."
  @spec url(Magpie.Client.t(), binary(), keyword()) ::
          {:ok, binary()} | {:error, Exception.t()}
  def url(client, key, _opts \\ []) do
    safely(fn ->
      client
      |> Files.get_temporary_link(key)
      |> link_result()
    end)
  end

  @doc "Like `url/3`, but returns the URL directly and raises on failure."
  def url!(client, key, opts \\ []), do: url(client, key, opts) |> unwrap!()

  @doc "Returns a one-use direct-upload URL for `key`."
  @spec upload_url(Magpie.Client.t(), binary(), keyword()) ::
          {:ok, binary()} | {:error, Exception.t()}
  def upload_url(client, key, opts \\ []) do
    duration = Keyword.get(opts, :duration, 14_400)

    commit = %{
      "path" => key,
      "mode" => write_mode(opts),
      "autorename" => Keyword.get(opts, :autorename, true),
      "mute" => Keyword.get(opts, :mute, false)
    }

    safely(fn ->
      client
      |> Files.get_temporary_upload_link(commit, duration)
      |> link_result()
    end)
  end

  @doc "Like `upload_url/3`, but returns the URL directly and raises on failure."
  def upload_url!(client, key, opts \\ []), do: upload_url(client, key, opts) |> unwrap!()

  @doc "Copies a Dropbox file or folder to `destination`."
  def copy(client, source, destination, _opts \\ []) do
    safely(fn -> Files.copy(client, source, destination) end)
  end

  @doc "Like `copy/4`, but returns metadata directly and raises on failure."
  def copy!(client, source, destination, opts \\ []),
    do: copy(client, source, destination, opts) |> unwrap!()

  @doc "Moves a Dropbox file or folder to `destination`."
  def move(client, source, destination, _opts \\ []) do
    safely(fn -> Files.move(client, source, destination) end)
  end

  @doc "Like `move/4`, but returns metadata directly and raises on failure."
  def move!(client, source, destination, opts \\ []),
    do: move(client, source, destination, opts) |> unwrap!()

  @doc "Creates a Dropbox folder at `key`."
  def mkdir(client, key, _opts \\ []) do
    safely(fn -> Files.create_folder(client, key) end)
  end

  @doc "Like `mkdir/3`, but returns metadata directly and raises on failure."
  def mkdir!(client, key, opts \\ []), do: mkdir(client, key, opts) |> unwrap!()

  @doc """
  Uploads several `{key, source}` or `{key, source, options}` entries concurrently.

  Results keep input order and each item is isolated as `{key, result}`. Batch
  options are `:max_concurrency`, `:timeout` and a two-argument
  `:on_progress` callback receiving `(key, result)`; remaining options are
  passed to every upload.
  """
  def put_many(client, entries, opts \\ []) when is_list(entries) do
    common_opts = Keyword.drop(opts, @batch_options)

    batch(entries, opts, :put, fn entry ->
      {key, source, item_opts} = put_entry(entry)
      {key, put(client, key, source, Keyword.merge(common_opts, item_opts))}
    end)
  end

  @doc """
  Deletes several keys concurrently while preserving input order and isolating failures.

  Accepts the same batch options as `put_many/3`; remaining options are
  passed to every deletion.
  """
  def delete_many(client, keys, opts \\ []) when is_list(keys) do
    delete_opts = Keyword.drop(opts, @batch_options)
    batch(keys, opts, :delete, fn key -> {key, delete(client, key, delete_opts)} end)
  end

  defp put_with_hash(client, key, source, opts, hash_fun) do
    needs_hash = Keyword.get(opts, :verify, false) or Keyword.get(opts, :skip_unchanged, false)
    expected_hash = if needs_hash, do: hash_fun.()

    case maybe_unchanged(client, key, expected_hash, opts) do
      {:unchanged, metadata} ->
        {:ok, :unchanged, metadata}

      :upload ->
        opts =
          if Keyword.get(opts, :verify, false),
            do: Keyword.put(opts, :expected_hash, expected_hash),
            else: opts

        upload_source(client, key, source, opts)

      {:error, _} = error ->
        error
    end
  end

  defp maybe_unchanged(client, key, hash, opts) do
    if Keyword.get(opts, :skip_unchanged, false) do
      case Files.get_metadata(client, key) do
        {:ok, %Magpie.FileMetadata{content_hash: ^hash} = metadata} ->
          {:unchanged, metadata}

        {:ok, _metadata} ->
          :upload

        {:error, %Error{} = error} ->
          if Error.not_found?(error), do: :upload, else: {:error, error}
      end
    else
      :upload
    end
  end

  defp upload_source(client, key, {:file, path}, opts),
    do: Files.upload_file(client, key, path, opts)

  defp upload_source(client, key, {:binary, data}, opts),
    do: Files.upload_data(client, key, data, opts)

  defp put_entry({key, source}), do: {key, source, []}
  defp put_entry({key, source, opts}) when is_list(opts), do: {key, source, opts}

  defp put_entry(entry) do
    raise ArgumentError,
          "expected a batch entry to be {key, source} or {key, source, options}, got: #{inspect(entry)}"
  end

  defp batch(items, opts, operation, fun) do
    task_opts = [
      ordered: true,
      max_concurrency: Keyword.get(opts, :max_concurrency, System.schedulers_online()),
      timeout: Keyword.get(opts, :timeout, :infinity),
      on_timeout: :kill_task
    ]

    callback = progress_callback(opts)

    results =
      items
      |> Task.async_stream(fn item -> isolated(fun, item) end, task_opts)
      |> Enum.zip(items)
      |> Enum.map(fn {task_result, item} ->
        {key, result} = batch_result(task_result, operation, batch_key(item))
        if callback, do: callback.(key, result)
        {key, result}
      end)

    {:ok, results}
  end

  defp isolated(fun, item) do
    fun.(item)
  rescue
    error -> {batch_key(item), {:error, error}}
  catch
    kind, reason ->
      {batch_key(item),
       {:error,
        %Magpie.BatchError{operation: :worker, key: batch_key(item), reason: {kind, reason}}}}
  end

  defp batch_result({:ok, {key, result}}, _operation, _fallback_key), do: {key, result}

  defp batch_result({:exit, reason}, operation, key),
    do: {key, {:error, %Magpie.BatchError{operation: operation, key: key, reason: reason}}}

  defp batch_key({key, _source}), do: key
  defp batch_key({key, _source, _opts}), do: key
  defp batch_key(key), do: key

  defp progress_callback(opts) do
    case Keyword.get(opts, :on_progress) do
      nil ->
        nil

      callback when is_function(callback, 2) ->
        callback

      callback ->
        raise ArgumentError,
              ":on_progress must be a two-argument function, got: #{inspect(callback)}"
    end
  end

  defp validate_progress!(opts) do
    case Keyword.get(opts, :progress) do
      nil ->
        :ok

      callback when is_function(callback, 2) ->
        :ok

      callback ->
        raise ArgumentError,
              ":progress must be a two-argument function, got: #{inspect(callback)}"
    end
  end

  defp write_mode(opts) do
    case Keyword.fetch(opts, :if_rev) do
      {:ok, rev} when is_binary(rev) -> %{".tag" => "update", "update" => rev}
      {:ok, rev} -> raise ArgumentError, ":if_rev must be a revision string, got: #{inspect(rev)}"
      :error -> Keyword.get(opts, :mode, "add")
    end
  end

  defp link_result({:ok, %{"link" => link}}), do: {:ok, link}
  defp link_result({:error, _} = error), do: error

  defp maybe_create_parent(destination, opts) do
    if Keyword.get(opts, :mkdir_p, false) do
      destination |> Path.dirname() |> File.mkdir_p()
    else
      :ok
    end
  end

  defp option_map(opts, allowed \\ :all)

  defp option_map(opts, :all), do: Map.new(opts, fn {key, value} -> {to_string(key), value} end)

  defp option_map(opts, allowed) do
    opts
    |> Keyword.take(allowed)
    |> option_map()
  end

  defp safely(fun) do
    fun.()
  rescue
    error in [Error, Req.TransportError, Req.HTTPError, File.Error] -> {:error, error}
  end

  defp unwrap!({:ok, :unchanged, value}), do: {:unchanged, value}
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, error}) when is_exception(error), do: raise(error)
  defp unwrap!({:error, reason}), do: raise("Magpie storage operation failed: #{inspect(reason)}")
end
