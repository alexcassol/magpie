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

  @type source :: {:file, Path.t()} | {:binary, iodata()} | {:stream, Enumerable.t()}
  @type result(value) :: {:ok, value} | {:error, Error.t() | File.posix()}

  @doc """
  Uploads a file, binary/iodata value, or stream to `key`.

  Options are `:mode`, `:autorename`, `:mute`, `:chunk_size` and
  `:session_threshold`; they have the same defaults as
  `Magpie.Files.upload_file/4`.
  """
  @spec put(Magpie.Client.t(), binary(), source(), keyword()) ::
          result(Magpie.FileMetadata.t())
  def put(client, key, source, opts \\ [])

  def put(client, key, {:file, path}, opts),
    do: Files.upload_file(client, key, path, opts)

  def put(client, key, {:binary, data}, opts),
    do: Files.upload_data(client, key, data, opts)

  def put(client, key, {:stream, enumerable}, opts),
    do: Files.upload_stream(client, key, enumerable, opts)

  def put(_client, _key, source, _opts) do
    raise ArgumentError,
          "expected source to be {:file, path}, {:binary, iodata}, or {:stream, enumerable}, got: #{inspect(source)}"
  end

  @doc "Like `put/4`, but returns metadata directly and raises on failure."
  def put!(client, key, source, opts \\ []), do: put(client, key, source, opts) |> unwrap!()

  @doc """
  Downloads `key` into memory and returns its bytes.

  Pass `with_headers: true` to retain the `%{body: body, headers: headers}`
  response shape used by `Magpie.Files.download/2`.
  """
  @spec get(Magpie.Client.t(), binary(), keyword()) :: result(binary() | map())
  def get(client, key, opts \\ []) do
    case Files.download(client, key) do
      {:ok, %{body: body} = response} ->
        if Keyword.get(opts, :with_headers, false), do: {:ok, response}, else: {:ok, body}

      {:error, _} = error ->
        error
    end
  end

  @doc "Like `get/3`, but returns the bytes directly and raises on failure."
  def get!(client, key, opts \\ []), do: get(client, key, opts) |> unwrap!()

  @doc """
  Streams `key` to a local destination and returns that destination.

  The destination's parent must exist unless `mkdir_p: true` is passed.
  An existing destination is replaced only after Dropbox successfully sends
  the complete response.
  """
  @spec download(Magpie.Client.t(), binary(), Path.t(), keyword()) :: result(Path.t())
  def download(client, key, destination, opts \\ []) do
    with :ok <- maybe_create_parent(destination, opts),
         {:ok, %{path: path}} <- Files.download_file(client, key, destination) do
      {:ok, path}
    end
  end

  @doc "Like `download/4`, but returns the destination directly and raises on failure."
  def download!(client, key, destination, opts \\ []),
    do: download(client, key, destination, opts) |> unwrap!()

  @doc "Deletes a Dropbox file or folder and returns its final metadata."
  def delete(client, key, opts \\ []) do
    Files.delete_folder(client, key, option_map(opts, [:parent_rev]))
  end

  @doc "Like `delete/3`, but returns metadata directly and raises on failure."
  def delete!(client, key, opts \\ []), do: delete(client, key, opts) |> unwrap!()

  @doc "Returns `true`, `false` for a missing key, or an error tuple for other failures."
  @spec exists?(Magpie.Client.t(), binary(), keyword()) :: boolean() | {:error, Error.t()}
  def exists?(client, key, opts \\ []) do
    case stat(client, key, opts) do
      {:ok, _metadata} -> true
      {:error, %Error{} = error} -> if Error.not_found?(error), do: false, else: {:error, error}
    end
  end

  @doc "Returns typed Dropbox metadata for `key`."
  def stat(client, key, opts \\ []) do
    Files.get_metadata(
      client,
      key,
      Keyword.get(opts, :include_media_info, false),
      Keyword.get(opts, :include_deleted, false),
      Keyword.get(opts, :include_has_explicit_shared_members, false)
    )
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
    {:ok, client |> stream(prefix, opts) |> Enum.to_list()}
  rescue
    error in [Error, Req.TransportError, Req.HTTPError] -> {:error, error}
  end

  @doc "Like `list/3`, but returns entries directly and raises on failure."
  def list!(client, prefix \\ "", opts \\ []), do: list(client, prefix, opts) |> unwrap!()

  @doc "Returns a lazy stream over every entry below `prefix`."
  @spec stream(Magpie.Client.t(), binary(), keyword()) :: Enumerable.t()
  def stream(client, prefix \\ "", opts \\ []) do
    ListFolder.stream(client, prefix, option_map(opts))
  end

  @doc "Returns a temporary direct-download URL for `key`."
  @spec url(Magpie.Client.t(), binary(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def url(client, key, _opts \\ []) do
    client
    |> Files.get_temporary_link(key)
    |> link_result()
  end

  @doc "Like `url/3`, but returns the URL directly and raises on failure."
  def url!(client, key, opts \\ []), do: url(client, key, opts) |> unwrap!()

  @doc "Returns a one-use direct-upload URL for `key`."
  @spec upload_url(Magpie.Client.t(), binary(), keyword()) ::
          {:ok, binary()} | {:error, Error.t()}
  def upload_url(client, key, opts \\ []) do
    duration = Keyword.get(opts, :duration, 14_400)

    commit = %{
      "path" => key,
      "mode" => Keyword.get(opts, :mode, "add"),
      "autorename" => Keyword.get(opts, :autorename, true),
      "mute" => Keyword.get(opts, :mute, false)
    }

    client
    |> Files.get_temporary_upload_link(commit, duration)
    |> link_result()
  end

  @doc "Like `upload_url/3`, but returns the URL directly and raises on failure."
  def upload_url!(client, key, opts \\ []), do: upload_url(client, key, opts) |> unwrap!()

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

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, error}) when is_exception(error), do: raise(error)
  defp unwrap!({:error, reason}), do: raise("Magpie storage operation failed: #{inspect(reason)}")
end
