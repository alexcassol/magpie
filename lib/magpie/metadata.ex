defmodule Magpie.Metadata do
  @moduledoc """
  Decodes the metadata objects of the `files` endpoints into structs.

  Dropbox describes every entry in a user's Dropbox with one of three
  objects, told apart by a `".tag"` key: `"file"`, `"folder"` or `"deleted"`.
  Magpie turns them into `Magpie.FileMetadata`, `Magpie.FolderMetadata` and
  `Magpie.DeletedMetadata`, with `DateTime` timestamps and a first-class
  `content_hash`, so callers pattern match on the struct instead of
  inspecting string keys:

      client
      |> Magpie.Files.ListFolder.stream("/Photos")
      |> Enum.map(fn
        %Magpie.FileMetadata{name: name, size: size} -> {name, size}
        %Magpie.FolderMetadata{name: name} -> {name, :folder}
        %Magpie.DeletedMetadata{name: name} -> {name, :deleted}
      end)

  Every function in `Magpie.Files`, `Magpie.Files.ListFolder` and
  `Magpie.Files.UploadSession` that returns metadata decodes it before
  handing it back, so `decode/1` is only needed when you call an endpoint
  yourself through `Magpie.post/3`:

      {:ok, raw} = Magpie.post(client, "/files/get_metadata", %{"path" => "/a.txt"})
      %Magpie.FileMetadata{} = Magpie.Metadata.decode(raw)

  ## Forward compatibility

  Decoding is lenient by design. A map whose `".tag"` Magpie does not know
  (should Dropbox add a fourth kind of entry) is returned untouched, and so
  is anything that is not a map — a stubbed test response, or an error
  payload that reached the decoder. Fields Dropbox adds later that the
  structs do not carry are dropped; the raw payload is always available
  through `Magpie.post/3`.
  """

  alias Magpie.DeletedMetadata
  alias Magpie.FileMetadata
  alias Magpie.FolderMetadata

  @type t :: FileMetadata.t() | FolderMetadata.t() | DeletedMetadata.t()

  # Dropbox hashes files in 4 MiB blocks.
  @block_size 4 * 1024 * 1024

  @doc """
  Decodes one metadata object.

  The `".tag"` picks the struct. Dropbox omits the tag when the endpoint's
  return type is known up front — `/files/upload` and `/files/list_revisions`
  always answer with files, `/files/create_folder_v2` with a folder — and
  `kind` says what to expect then: `:file`, `:folder`, or `:infer` (the
  default), which treats a map with a `"rev"` as a file (every file has one,
  no folder does) and any other map with a `"name"` as a folder. Unknown tags
  and non-map values are returned as they are.

      iex> Magpie.Metadata.decode(%{".tag" => "folder", "name" => "Photos", "id" => "id:1"})
      %Magpie.FolderMetadata{name: "Photos", id: "id:1"}

      iex> Magpie.Metadata.decode(%{"name" => "a.txt", "rev" => "015", "size" => 3})
      %Magpie.FileMetadata{name: "a.txt", rev: "015", size: 3}

      iex> Magpie.Metadata.decode(%{"name" => "a.txt"}, :file)
      %Magpie.FileMetadata{name: "a.txt"}

      iex> Magpie.Metadata.decode(%{".tag" => "hologram", "name" => "x"})
      %{".tag" => "hologram", "name" => "x"}

  """
  @spec decode(term(), :infer | :file | :folder) :: t() | term()
  def decode(value, kind \\ :infer)

  def decode(%{".tag" => "file"} = map, _kind), do: FileMetadata.from_map(map)
  def decode(%{".tag" => "folder"} = map, _kind), do: FolderMetadata.from_map(map)
  def decode(%{".tag" => "deleted"} = map, _kind), do: DeletedMetadata.from_map(map)
  def decode(%{".tag" => _other} = map, _kind), do: map
  def decode(%{} = map, :file), do: FileMetadata.from_map(map)
  def decode(%{} = map, :folder), do: FolderMetadata.from_map(map)
  def decode(%{"rev" => _rev} = map, :infer), do: FileMetadata.from_map(map)
  def decode(%{"name" => _name} = map, :infer), do: FolderMetadata.from_map(map)
  def decode(other, _kind), do: other

  @doc """
  Decodes a response that wraps the metadata under a `"metadata"` key —
  `/files/create_folder_v2`, `/files/delete_v2`, `/files/copy_v2` and
  `/files/move_v2` all answer that way — returning just the struct.

  `kind` is passed on to `decode/2`. Responses of any other shape are
  returned untouched.

      iex> Magpie.Metadata.unwrap(%{"metadata" => %{".tag" => "file", "name" => "a", "rev" => "1"}})
      %Magpie.FileMetadata{name: "a", rev: "1"}

  """
  @spec unwrap(term(), :infer | :file | :folder) :: t() | term()
  def unwrap(value, kind \\ :infer)
  def unwrap(%{"metadata" => metadata}, kind), do: decode(metadata, kind)
  def unwrap(other, _kind), do: other

  @doc """
  Decodes every item under `"entries"` of a paginated page, leaving the rest
  of the page — `"cursor"`, `"has_more"` — as it is, so the page still drives
  `Magpie.Pager`. `kind` is passed on to `decode/2`.

      iex> Magpie.Metadata.decode_page(%{"entries" => [%{".tag" => "deleted", "name" => "x"}], "has_more" => false})
      %{"entries" => [%Magpie.DeletedMetadata{name: "x"}], "has_more" => false}

  """
  @spec decode_page(term(), :infer | :file | :folder) :: term()
  def decode_page(page, kind \\ :infer)

  def decode_page(%{"entries" => entries} = page, kind) when is_list(entries),
    do: %{page | "entries" => Enum.map(entries, &decode(&1, kind))}

  def decode_page(other, _kind), do: other

  @doc """
  Decodes the `"metadata"` of every search match on a `/files/search_v2`
  page. Dropbox wraps each match's entry in a one-variant union
  (`%{".tag" => "metadata", "metadata" => ...}`); Magpie flattens it so the
  match holds the struct directly.

      iex> page = %{"matches" => [%{"metadata" => %{".tag" => "metadata", "metadata" => %{".tag" => "file", "name" => "a", "rev" => "1"}}}]}
      iex> Magpie.Metadata.decode_matches(page)
      %{"matches" => [%{"metadata" => %Magpie.FileMetadata{name: "a", rev: "1"}}]}

  """
  @spec decode_matches(term()) :: term()
  def decode_matches(%{"matches" => matches} = page) when is_list(matches),
    do: %{page | "matches" => Enum.map(matches, &decode_match/1)}

  def decode_matches(other), do: other

  defp decode_match(%{"metadata" => %{".tag" => "metadata", "metadata" => metadata}} = match),
    do: %{match | "metadata" => decode(metadata)}

  defp decode_match(match), do: match

  @doc """
  Computes the Dropbox `content_hash` of `data` — a binary, or an enumerable
  of binaries such as `File.stream!/2` — so a transfer can be verified
  against `Magpie.FileMetadata.content_hash` without another request.

  Dropbox hashes the content in 4 MiB blocks with SHA-256, concatenates the
  block digests and hashes the result once more (see the
  [Content hash](https://www.dropbox.com/developers/reference/content-hash)
  reference).

      iex> Magpie.Metadata.content_hash("")
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

      {:ok, %{body: body}} = Magpie.Files.download(client, "/report.pdf")
      {:ok, %Magpie.FileMetadata{content_hash: hash}} = Magpie.Files.get_metadata(client, "/report.pdf")
      Magpie.Metadata.content_hash(body) == hash
      # => true

  """
  @spec content_hash(binary() | Enumerable.t()) :: String.t()
  def content_hash(data) when is_binary(data), do: content_hash([data])

  def content_hash(chunks) do
    {digests, rest} =
      Enum.reduce(chunks, {[], <<>>}, fn chunk, {digests, buffer} ->
        hash_blocks(buffer <> chunk, digests)
      end)

    # A trailing partial block is hashed on its own; an empty input has no
    # blocks at all, so its hash is the SHA-256 of nothing.
    digests = if rest == <<>>, do: digests, else: [sha256(rest) | digests]

    digests
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> sha256()
    |> Base.encode16(case: :lower)
  end

  defp hash_blocks(<<block::binary-size(@block_size), rest::binary>>, digests),
    do: hash_blocks(rest, [sha256(block) | digests])

  defp hash_blocks(rest, digests), do: {digests, rest}

  defp sha256(data), do: :crypto.hash(:sha256, data)

  @doc false
  # Applies `fun` to the body of a successful response, passing errors through.
  def map_ok({:ok, body}, fun), do: {:ok, fun.(body)}
  def map_ok(other, _fun), do: other

  @doc false
  # Dropbox timestamps are `%Y-%m-%dT%H:%M:%SZ`; anything else is left alone
  # rather than crashing the decode.
  def parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> value
    end
  end

  def parse_timestamp(value), do: value
end
