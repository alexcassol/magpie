# Upgrading Magpie

## From 0.5 to 0.6

Magpie 0.6 is additive: existing 0.5 calls keep their signatures and successful
results. The `Storage` layer now also returns expected Req transport failures as
`{:error, exception}` instead of raising; bang variants still raise.

New `Storage` capabilities include:

- verified uploads with `verify: true` and `%Magpie.IntegrityError{}`
- unchanged-file detection with `skip_unchanged: true`
- conditional writes with `if_rev: rev`
- transfer `progress: fn transferred, total -> ... end`
- `copy/4`, `move/4`, `mkdir/3`, `put_many/3` and `delete_many/3`
- Dropbox request IDs on `%Magpie.Error{}` and request/retry telemetry

Automatic retries apply only to selected read-only file routes: downloads,
metadata, temporary links, listings, revisions and search. Mutation endpoints
remain single-attempt because repeating a timed-out write can create duplicate
effects.

Use 0.6.1 or newer. Version 0.6.1 fixes a regression in 0.6.0 that allowed
Dropbox API errors raised during `Storage.list/3` pagination to escape instead
of returning `{:error, %Magpie.Error{}}`.

```elixir
def deps do
  [{:magpie, "~> 0.6.1"}]
end
```

## From 0.3 to 0.4

Magpie 0.4 decodes the metadata of the `files` endpoints into structs —
`Magpie.FileMetadata`, `Magpie.FolderMetadata` and `Magpie.DeletedMetadata`
— instead of handing back the raw JSON maps with their `".tag"` keys. Code
written against 0.3 that reads those maps needs a small update. This guide
lists every call whose result changed, with the 0.3 and 0.4 versions side
by side.

Nothing else moved: clients, OAuth, the token server, uploads, pagination,
`Magpie.Async`, the sharing/users/file-requests modules and the
`{:ok, result} | {:error, %Magpie.Error{}}` contract are untouched.

## Bump the dependency

```elixir
def deps do
  [
    {:magpie, "~> 0.4"}
  ]
end
```

Magpie now requires `req ~> 0.7.4` and declares its own dependency on
`jason`, which it always used for the `Dropbox-API-Arg` header. Neither
should need attention unless your app pins an older Req.

## What a struct looks like

Every field Dropbox documents for a file is a field on the struct, with a
few upgrades over the raw map:

- `client_modified` and `server_modified` are `DateTime` structs, not
  strings
- `content_hash` is a first-class field, and `Magpie.Metadata.content_hash/1`
  computes the same hash locally so you can verify a transfer
- `is_downloadable` defaults to `true` when Dropbox omits it
- nested objects Dropbox may attach (`sharing_info`, `media_info`,
  `symlink_info`, `export_info`, `file_lock_info`, `property_groups`) stay
  raw maps

```elixir
%Magpie.FileMetadata{
  name: "report.pdf",
  id: "id:a4ayc_80_OEAAAAAAAAAXw",
  path_lower: "/backup/report.pdf",
  path_display: "/Backup/report.pdf",
  client_modified: ~U[2026-09-01 15:50:38Z],
  server_modified: ~U[2026-09-01 15:50:39Z],
  rev: "015d5ff0b3f0e4a000000027c3f9a10",
  size: 48_213,
  content_hash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  is_downloadable: true,
  ...
}
```

The kind of entry is the struct itself — there is no `".tag"` to inspect.

## Which calls changed

| Call | 0.3 returned | 0.4 returns |
| --- | --- | --- |
| `Magpie.Files.get_metadata/5` | map with `".tag"` | `%FileMetadata{}`, `%FolderMetadata{}` or `%DeletedMetadata{}` |
| `Magpie.Files.upload/6`, `upload_file/4` | map | `%FileMetadata{}` |
| `Magpie.Files.UploadSession.finish/8`, `finish_data/5` | map | `%FileMetadata{}` |
| `Magpie.Files.restore/3` | map | `%FileMetadata{}` |
| `Magpie.Files.create_folder/2` | `%{"metadata" => map}` | `%FolderMetadata{}` (unwrapped) |
| `Magpie.Files.delete_folder/2`, `copy/3`, `move/3` | `%{"metadata" => map}` | `%FileMetadata{}` or `%FolderMetadata{}` (unwrapped) |
| `Magpie.Files.ListFolder.list_folder/3`, `list_folder_continue/2` | page with map entries | same page, entries are structs |
| `Magpie.Files.ListFolder.stream/3` | stream of maps | stream of structs |
| `Magpie.Files.ListFolder.list_revisions/4` | page with map entries | same page, entries are `%FileMetadata{}` |
| `Magpie.Files.search/3`, `search_continue/2`, `search_stream/3` | matches with `"metadata" => %{".tag" => "metadata", "metadata" => map}` | matches with `"metadata" => struct` (union flattened) |
| `Magpie.LiveView.UploadWriter.meta/1` | `%{path: path, metadata: map}` | `%{path: path, metadata: %FileMetadata{}}` |

Page envelopes (`"entries"`, `"cursor"`, `"has_more"`, `"is_deleted"`) and
search matches (`"match_type"`, `"highlights"`) keep their string keys — only
the metadata inside them changed. Batch results (`finish_batch/2`,
`Magpie.Files.CopyBatch`, `MoveBatch`, `DeleteBatch`, ...) and everything
outside `Magpie.Files` are as they were.

## Before and after

### Reading fields

```elixir
# 0.3
{:ok, metadata} = Magpie.Files.get_metadata(client, "/report.pdf")
metadata["size"]
metadata["server_modified"]                        # "2026-09-01T15:50:39Z"

# 0.4
{:ok, %Magpie.FileMetadata{} = file} = Magpie.Files.get_metadata(client, "/report.pdf")
file.size
file.server_modified                               # ~U[2026-09-01 15:50:39Z]
DateTime.to_iso8601(file.server_modified)          # the old string, if you stored it
```

### Telling files and folders apart

```elixir
# 0.3
client
|> Magpie.Files.ListFolder.stream("/Photos")
|> Stream.filter(&(&1[".tag"] == "file"))
|> Enum.map(& &1["name"])

# 0.4
client
|> Magpie.Files.ListFolder.stream("/Photos")
|> Stream.filter(&match?(%Magpie.FileMetadata{}, &1))
|> Enum.map(& &1.name)
```

Or match on all three kinds at once:

```elixir
Enum.map(entries, fn
  %Magpie.FileMetadata{name: name, size: size} -> {:file, name, size}
  %Magpie.FolderMetadata{name: name} -> {:folder, name}
  %Magpie.DeletedMetadata{name: name} -> {:deleted, name}
end)
```

### Uploads

```elixir
# 0.3
{:ok, metadata} = Magpie.Files.upload_file(client, "/Backup/db.dump", "priv/db.dump")
Logger.info("uploaded #{metadata["name"]} (#{metadata["size"]} bytes)")

# 0.4
{:ok, %Magpie.FileMetadata{} = file} = Magpie.Files.upload_file(client, "/Backup/db.dump", "priv/db.dump")
Logger.info("uploaded #{file.name} (#{file.size} bytes)")

# New in 0.4: verify the upload against the hash Dropbox computed
file.content_hash == Magpie.Metadata.content_hash(File.stream!("priv/db.dump", 4 * 1024 * 1024))
```

### Wrapped results: create, delete, copy, move

The `"metadata"` envelope is gone — the struct is the whole result.

```elixir
# 0.3
{:ok, %{"metadata" => %{"id" => id}}} = Magpie.Files.create_folder(client, "/Photos")
{:ok, %{"metadata" => moved}} = Magpie.Files.move(client, "/a.txt", "/b.txt")

# 0.4
{:ok, %Magpie.FolderMetadata{id: id}} = Magpie.Files.create_folder(client, "/Photos")
{:ok, %Magpie.FileMetadata{} = moved} = Magpie.Files.move(client, "/a.txt", "/b.txt")
```

The same applies to error handling that matched on the envelope:

```elixir
# 0.3
case Magpie.Files.create_folder(client, "/Existing") do
  {:ok, %{"metadata" => metadata}} -> metadata
  {:error, %Magpie.Error{status: 409, summary: "path/conflict" <> _}} -> :already_exists
end

# 0.4
case Magpie.Files.create_folder(client, "/Existing") do
  {:ok, %Magpie.FolderMetadata{} = folder} -> folder
  {:error, %Magpie.Error{status: 409, summary: "path/conflict" <> _}} -> :already_exists
end
```

### Search

Dropbox wraps each match's entry in a one-variant union; 0.4 flattens it.

```elixir
# 0.3
{:ok, %{"matches" => matches}} = Magpie.Files.search(client, "invoice")
Enum.map(matches, & &1["metadata"]["metadata"]["path_display"])

# 0.4
{:ok, %{"matches" => matches}} = Magpie.Files.search(client, "invoice")
Enum.map(matches, & &1["metadata"].path_display)
```

### LiveView uploads

```elixir
# 0.3
consume_uploaded_entries(socket, :report, fn %{metadata: metadata}, _entry ->
  {:ok, metadata["path_display"]}
end)

# 0.4
consume_uploaded_entries(socket, :report, fn %{metadata: metadata}, _entry ->
  {:ok, metadata.path_display}
end)
```

### Tests that stub Dropbox

Stubs keep returning JSON — Magpie decodes it on the way in — so only the
assertions change. Include the `".tag"` in stubbed entries, exactly as
Dropbox sends it, so each one decodes into the struct you expect:

```elixir
# 0.3
Req.Test.stub(Magpie, fn conn ->
  Req.Test.json(conn, %{"entries" => [%{"name" => "db.dump"}]})
end)

assert {:ok, %{"entries" => [%{"name" => "db.dump"}]}} = MyApp.Backups.list()

# 0.4
Req.Test.stub(Magpie, fn conn ->
  Req.Test.json(conn, %{"entries" => [%{".tag" => "file", "name" => "db.dump", "rev" => "015"}]})
end)

assert {:ok, %{"entries" => [%Magpie.FileMetadata{name: "db.dump"}]}} = MyApp.Backups.list()
```

An entry stubbed without a `".tag"` is decoded like Dropbox's untagged
responses: as a file when it has a `"rev"`, as a folder otherwise — except
on calls that only ever return files (`upload`, `upload_file`, `finish_data`,
`restore`, `list_revisions`), where it is always a file.

## Deprecated

- `Magpie.Files.create_folder_to_struct/2` and `delete_folder_to_struct/2`
  still return the legacy `%Magpie.Folder{}`, but emit a deprecation warning
  at compile time. Use `create_folder/2` and `delete_folder/2` directly —
  they return the richer `Magpie.FolderMetadata` now.
- `Magpie.Folder` is kept only for those two functions.

## Keeping the raw maps

If some code needs the untouched payload — a field Magpie does not map, or a
migration you would rather do gradually — call the endpoint through
`Magpie.post/3`, which never decodes:

```elixir
{:ok, raw} = Magpie.post(client, "/files/get_metadata", %{"path" => "/report.pdf"})
raw["server_modified"]
# => "2026-09-01T15:50:39Z"

# ...and decode it yourself when ready
%Magpie.FileMetadata{} = Magpie.Metadata.decode(raw)
```
