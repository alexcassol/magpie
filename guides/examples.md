# Examples

Real-world recipes for common Dropbox tasks with Magpie. All examples assume
a client:

```elixir
# Short-lived: Dropbox access tokens expire in about 4 hours
client = Magpie.Client.new(System.fetch_env!("DROPBOX_ACCESS_TOKEN"))

# Long-running: Magpie keeps the access token fresh from a refresh token
client =
  Magpie.Client.new(
    refresh_token: System.fetch_env!("DROPBOX_REFRESH_TOKEN"),
    app_key: System.fetch_env!("DROPBOX_APP_KEY"),
    app_secret: System.fetch_env!("DROPBOX_APP_SECRET")
  )
```

## Checking your credentials

```elixir
# Validates the user token — Dropbox echoes the query back
{:ok, %{"result" => "ping"}} = Magpie.Check.user(client)

# Who am I?
{:ok, %{"email" => email}} = Magpie.Users.current_account(client)

# A token Dropbox no longer accepts comes back as a plain error
{:error, %Magpie.Error{status: 401, summary: "invalid_access_token/.."}} =
  Magpie.Check.user(Magpie.Client.new("nope"))
```

## Staying authenticated for more than 4 hours

Anything that runs unattended — a nightly backup, a worker, a daemon —
needs a refresh token instead of an access token. Put the token holder in
your supervision tree and point clients at it:

```elixir
# lib/my_app/application.ex
children = [
  {Magpie.Auth.TokenServer,
   name: MyApp.DropboxToken,
   app_key: System.fetch_env!("DROPBOX_APP_KEY"),
   app_secret: System.fetch_env!("DROPBOX_APP_SECRET"),
   refresh_token: System.fetch_env!("DROPBOX_REFRESH_TOKEN")}
]
```

```elixir
# Cheap to build — the token lives in the server, not in the struct
client = Magpie.Client.new(token_provider: {Magpie.Auth.TokenServer, MyApp.DropboxToken})

# Runs at 3am on day 40 just like it did on day 1
{:ok, _} = Magpie.Files.upload_file(client, "/Backup/db.dump", "priv/db.dump")
```

The access token is renewed a few minutes before it expires, concurrent
requests share a single refresh, and a request rejected as
`expired_access_token` is refreshed and replayed once — none of which you
have to write.

Getting that refresh token takes a browser round-trip, once:

```elixir
# 1. Open this URL, approve the app, copy the code Dropbox shows
Magpie.Auth.authorize_url(app_key)

# 2. Trade the code for tokens and store the refresh one as a secret
{:ok, token} = Magpie.Auth.exchange_code(app_key, code, app_secret: app_secret)
token.refresh_token
```

The [OAuth guide](oauth.html) covers the whole picture: the web redirect
flow, PKCE for apps that cannot keep a secret, persisting tokens with
`:on_refresh`, and writing your own `Magpie.Auth.TokenProvider` when tokens
live in your database.

## Using Dropbox as simple storage

`Magpie.Storage` is the recommended entry point when you need storage rather
than a Dropbox-specific endpoint. It offers an object-storage-style API while
still using Dropbox paths — there are no S3 buckets or S3 compatibility:

```elixir
alias Magpie.Storage

# A local file: small files use one request, large ones use an upload session
{:ok, %Magpie.FileMetadata{} = invoice} =
  Storage.put(client, "/Invoices/2026-09.pdf", {:file, "priv/invoice.pdf"})

# In-memory content can be a binary or iodata
{:ok, %Magpie.FileMetadata{}} =
  Storage.put(
    client,
    "/Exports/status.json",
    {:binary, Jason.encode_to_iodata!(%{status: "ready"})},
    mode: "overwrite"
  )

# Any enumerable of binary/iodata chunks is uploaded without collecting it all
csv_rows = Stream.map(rows, fn row -> [to_string(row.id), ",", row.email, "\n"] end)
{:ok, %Magpie.FileMetadata{}} =
  Storage.put(client, "/Exports/users.csv", {:stream, csv_rows})
```

Use `get/3` when the file belongs in memory and `download/4` for large files.
`download/4` writes to a temporary sibling first, so an API failure does not
replace an existing destination:

```elixir
{:ok, json} = Storage.get(client, "/Exports/status.json")
%{"status" => "ready"} = Jason.decode!(json)

{:ok, "tmp/users.csv"} =
  Storage.download(client, "/Exports/users.csv", "tmp/users.csv", mkdir_p: true)

# Temporary direct-download links normally expire after four hours
{:ok, url} = Storage.url(client, "/Invoices/2026-09.pdf")
```

Metadata, existence checks and listings use the same small interface:

```elixir
true = Storage.exists?(client, "/Invoices/2026-09.pdf")
false = Storage.exists?(client, "/Invoices/missing.pdf")

{:ok, %Magpie.FileMetadata{size: size, content_hash: hash}} =
  Storage.stat(client, "/Invoices/2026-09.pdf")

# Eager: returns all cursor pages in one list
{:ok, entries} = Storage.list(client, "/Invoices", recursive: true)

# Lazy: fetches only as many pages as the consumer needs
recent_invoices =
  client
  |> Storage.stream("/Invoices", recursive: true)
  |> Stream.filter(&match?(%Magpie.FileMetadata{}, &1))
  |> Enum.take(10)

{:ok, %Magpie.FileMetadata{}} =
  Storage.delete(client, "/Invoices/2026-09.pdf")
```

For production uploads, Magpie can verify Dropbox's content hash and avoid
sending a local file or binary that is already identical:

```elixir
case Storage.put(client, "/Backup/db.dump", {:file, "priv/db.dump"},
       verify: true,
       skip_unchanged: true,
       progress: fn sent, total -> Logger.info("#{sent}/#{total} bytes") end
     ) do
  {:ok, :unchanged, %Magpie.FileMetadata{} = file} -> {:unchanged, file}
  {:ok, %Magpie.FileMetadata{} = file} -> {:uploaded, file}
  {:error, error} -> {:failed, error}
end
```

Use `if_rev` to replace only the revision your application last read. Dropbox
returns a conflict if another writer changed the file first:

```elixir
{:ok, %Magpie.FileMetadata{rev: rev}} = Storage.stat(client, "/state.json")

Storage.put(client, "/state.json", {:binary, Jason.encode!(new_state)},
  if_rev: rev,
  verify: true
)
```

Common relocation, folder and concurrent batch operations stay in the same
interface. Batch results preserve input order and isolate failures:

```elixir
{:ok, %Magpie.FolderMetadata{}} = Storage.mkdir(client, "/Archive")
{:ok, _} = Storage.copy(client, "/report.pdf", "/Archive/report.pdf")
{:ok, _} = Storage.move(client, "/draft.pdf", "/Archive/final.pdf")

{:ok, results} =
  Storage.put_many(
    client,
    [
      {"/Exports/one.json", {:binary, Jason.encode!(one)}},
      {"/Exports/two.json", {:binary, Jason.encode!(two)}, if_rev: two_rev}
    ],
    max_concurrency: 4,
    verify: true,
    on_progress: fn key, result -> Logger.debug("#{key}: #{inspect(result)}") end
  )

for {key, {:error, error}} <- results do
  message = if is_exception(error), do: Exception.message(error), else: inspect(error)
  Logger.warning("#{key}: #{message}")
end
```

Magpie emits `[:magpie, :request, :start | :stop | :exception | :retry]` and
`[:magpie, :transfer, :progress]` events. Stop metadata includes the HTTP
status and Dropbox request ID. This example observes completed, failed and
retried requests, plus transfer progress:

```elixir
defmodule MyApp.MagpieTelemetry do
  require Logger

  def handle_event([:magpie, :request, event], measurements, metadata, _config) do
    Logger.debug("Dropbox #{event}: #{metadata.operation} #{inspect(measurements)}")
  end

  def handle_event(
        [:magpie, :transfer, :progress],
        %{transferred: transferred, total: total},
        %{direction: direction, path: path},
        _config
      ) do
    Logger.debug("Dropbox #{direction} #{path}: #{transferred}/#{inspect(total)} bytes")
  end
end

request_events =
  for event <- [:stop, :exception, :retry], do: [:magpie, :request, event]

:telemetry.attach_many(
  "my-app-magpie",
  request_events ++ [[:magpie, :transfer, :progress]],
  &MyApp.MagpieTelemetry.handle_event/4,
  nil
)
```

Normal functions return success or error tuples; expected Req transport errors
are values too, so a failed network call does not bring down a background job.
For one-off scripts, bang variants such as `get!/3`, `download!/4` and
`delete!/3` return the value directly and raise on failure. `put!/4` does the
same after an upload, or returns `{:unchanged, metadata}` when
`skip_unchanged: true` avoids the upload. Use `Magpie.Files` when you need
Dropbox-specific operations beyond this storage interface.

## Uploading files

`Magpie.Files.upload_file/4` picks the right strategy for you: small files go
through a single request, files above 150 MiB are automatically streamed
through an upload session in chunks — without loading the file into memory:

```elixir
# Works the same for a 2 KB text file or a 40 GB backup
{:ok, %Magpie.FileMetadata{} = file} =
  Magpie.Files.upload_file(client, "/Backup/db.dump", "priv/db.dump")

file.size
# => 1_073_741_824

# Dropbox hashes what it stored — compare it with the local file
file.content_hash == Magpie.Metadata.content_hash(File.stream!("priv/db.dump", 4 * 1024 * 1024))
# => true

# Overwrite an existing file, with a custom chunk size
{:ok, _} =
  Magpie.Files.upload_file(client, "/Backup/db.dump", "priv/db.dump",
    mode: "overwrite",
    chunk_size: 16 * 1024 * 1024
  )
```

Uploads coming from a Phoenix controller or a LiveView form — including
streaming straight into Dropbox without touching your disk — are covered in
the [Phoenix guide](phoenix.html).

If you need manual control over the session (e.g. the data is generated on
the fly), use the lower-level primitives:

```elixir
{:ok, %{"session_id" => sid}} = Magpie.Files.UploadSession.start_data(client, chunk1)
{:ok, _} = Magpie.Files.UploadSession.append_data(client, sid, byte_size(chunk1), chunk2)

{:ok, %Magpie.FileMetadata{}} =
  Magpie.Files.UploadSession.finish_data(
    client,
    sid,
    byte_size(chunk1) + byte_size(chunk2),
    %{"path" => "/generated.bin"}
  )
```

## Downloading files

```elixir
# Into memory
{:ok, %{body: contents}} = Magpie.Files.download(client, "/Backup/db.dump")
File.write!("db.dump", contents)

# Verify it arrived intact
{:ok, %Magpie.FileMetadata{content_hash: hash}} = Magpie.Files.get_metadata(client, "/Backup/db.dump")
^hash = Magpie.Metadata.content_hash(contents)

# A whole folder as a zip
{:ok, %{body: zip}} = Magpie.Files.download_zip(client, "/Backup")
File.write!("backup.zip", zip)

# Or hand out a short-lived direct link instead
{:ok, %{"link" => url}} = Magpie.Files.get_temporary_link(client, "/Backup/db.dump")
```

## Working with metadata

The `files` endpoints describe every entry with one of three structs —
`Magpie.FileMetadata`, `Magpie.FolderMetadata` or `Magpie.DeletedMetadata`
— so the kind of entry is the struct you match on, timestamps are
`DateTime`s and the `content_hash` is a field (see `Magpie.Metadata`):

```elixir
{:ok, %Magpie.FileMetadata{} = file} = Magpie.Files.get_metadata(client, "/Backup/db.dump")

file.size
# => 1_073_741_824
file.server_modified
# => ~U[2026-09-01 03:00:12Z]
DateTime.diff(DateTime.utc_now(), file.server_modified, :hour)
# => 41

# Folders and files come from the same call
case Magpie.Files.get_metadata(client, path) do
  {:ok, %Magpie.FileMetadata{size: size}} -> {:file, size}
  {:ok, %Magpie.FolderMetadata{}} -> :folder
  {:error, %Magpie.Error{status: 409}} -> :not_found
end
```

Endpoints that answer with a result object (`create_folder/2`,
`delete_folder/2`, `copy/3`, `move/3`) are unwrapped, so the struct is the
whole result:

```elixir
{:ok, %Magpie.FolderMetadata{id: "id:" <> _}} = Magpie.Files.create_folder(client, "/Photos/2026")
{:ok, %Magpie.FileMetadata{path_display: "/Archive/a.txt"}} = Magpie.Files.move(client, "/a.txt", "/Archive/a.txt")
```

## Listing folders lazily

`Magpie.Files.ListFolder.stream/2` hides cursor pagination behind a regular
`Stream` — pages are only fetched as you consume it, and every entry is a
metadata struct:

```elixir
# All PDF names in a folder, no matter how many pages Dropbox returns
client
|> Magpie.Files.ListFolder.stream("/Documents")
|> Stream.filter(&match?(%Magpie.FileMetadata{}, &1))
|> Stream.filter(&String.ends_with?(&1.name, ".pdf"))
|> Enum.map(& &1.name)

# Lazy: only fetches as many pages as needed for the first 10 entries
client |> Magpie.Files.ListFolder.stream("/Photos") |> Enum.take(10)

# Files changed in the last day, largest first
client
|> Magpie.Files.ListFolder.stream("/Shared", %{"recursive" => true})
|> Stream.filter(&match?(%Magpie.FileMetadata{}, &1))
|> Stream.filter(&(DateTime.diff(DateTime.utc_now(), &1.server_modified, :day) < 1))
|> Enum.sort_by(& &1.size, :desc)

# Deleted entries show up as Magpie.DeletedMetadata when asked for
client
|> Magpie.Files.ListFolder.stream("/Inbox", %{"include_deleted" => true})
|> Enum.filter(&match?(%Magpie.DeletedMetadata{}, &1))
```

The same pattern is available for searches, shared folders and file
requests — and `Magpie.Pager.stream/3` lets you wrap any other paginated
endpoint yourself. Search matches carry their metadata struct under
`"metadata"`; the sharing and file-request streams are outside the `files`
namespace and yield Dropbox's maps as they are:

```elixir
client
|> Magpie.Files.search_stream("invoice", %{"path" => "/Work"})
|> Enum.map(fn %{"metadata" => %Magpie.FileMetadata{} = file} -> file.path_display end)

client |> Magpie.Sharing.list_folders_stream() |> Enum.map(& &1["name"])
client |> Magpie.FileRequests.stream() |> Enum.count()
```

## Batch operations without polling boilerplate

Batch endpoints may finish asynchronously and hand you an `async_job_id`.
`Magpie.Async.await/4` polls the matching check endpoint with exponential
backoff — and passes through jobs that completed synchronously, so you can
pipe it unconditionally:

```elixir
entries = [
  %{"from_path" => "/Old/a.txt", "to_path" => "/New/a.txt"},
  %{"from_path" => "/Old/b.txt", "to_path" => "/New/b.txt"}
]

{:ok, launch} = Magpie.Files.MoveBatch.move_batch(client, entries)

{:ok, %{"entries" => results}} =
  Magpie.Async.await(client, launch, &Magpie.Files.MoveBatch.check/2, timeout: 120_000)
```

## Shared links

```elixir
# Anyone with the link can view
{:ok, %{"url" => url}} =
  Magpie.Sharing.create_shared_link(client, "/report.pdf", %{"audience" => "public"})

# List existing links for a path, then revoke them
{:ok, %{"links" => links}} = Magpie.Sharing.list_shared_links(client, %{"path" => "/report.pdf"})
Enum.each(links, fn %{"url" => url} -> Magpie.Sharing.revoke_shared_link(client, url) end)
```

## File requests

```elixir
{:ok, request} =
  Magpie.FileRequests.create(client, "Send me the invoices", "/Inbox/Invoices", %{
    "deadline" => "2027-01-01T00:00:00Z"
  })

request["url"]
# => "https://www.dropbox.com/request/..."
```

## Handling errors

Successful calls return `{:ok, result}`. Dropbox errors come back as
`{:error, %Magpie.Error{}}` carrying the HTTP `status`, Dropbox's
`error_summary` and the full decoded error `body`:

```elixir
case Magpie.Files.create_folder(client, "/Existing") do
  {:ok, %Magpie.FolderMetadata{} = folder} ->
    folder

  {:error, %Magpie.Error{status: 409, summary: "path/conflict" <> _}} ->
    :already_exists

  {:error, error} ->
    # Magpie.Error is an exception — raise it when you cannot handle it
    raise error
end
```

Paginated streams raise `Magpie.Error` instead, since a `Stream`
cannot return a tuple mid-enumeration.

For storage operations, the classification helpers avoid matching the exact
Dropbox `error_summary`, which may gain extra path segments over time:

```elixir
case Magpie.Storage.get(client, "/Invoices/latest.pdf") do
  {:ok, contents} ->
    contents

  {:error, %Magpie.Error{} = error} ->
    cond do
      Magpie.Error.not_found?(error) -> :missing
      Magpie.Error.rate_limited?(error) -> :try_again_later
      true -> raise error
    end
end
```

## Testing your app

Magpie's requests can be routed to [`Req.Test`](https://hexdocs.pm/req/Req.Test.html)
stubs, so your test suite never touches the network. In `config/test.exs`:

```elixir
config :magpie, req_options: [plug: {Req.Test, Magpie}]
```

Then stub responses per test. Stubs return JSON exactly as Dropbox would —
including the `".tag"` on listed entries — and Magpie decodes it into the
same structs your code sees in production:

```elixir
test "lists the backup folder" do
  Req.Test.stub(Magpie, fn conn ->
    Req.Test.json(conn, %{
      "entries" => [%{".tag" => "file", "name" => "db.dump", "rev" => "015", "size" => 42}],
      "cursor" => "c",
      "has_more" => false
    })
  end)

  assert {:ok, [%Magpie.FileMetadata{name: "db.dump", size: 42}]} = MyApp.Backups.list()
end
```
