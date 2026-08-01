# Examples

Real-world recipes for common Dropbox tasks with Magpie. All examples assume
a client:

```elixir
client = Magpie.Client.new(System.fetch_env!("DROPBOX_ACCESS_TOKEN"))
```

## Checking your credentials

```elixir
# Validates the user token — Dropbox echoes the query back
{:ok, %{"result" => "ping"}} = Magpie.Check.user(client)

# Who am I?
{:ok, %{"email" => email}} = Magpie.Users.current_account(client)
```

## Uploading files

`Magpie.Files.upload_file/4` picks the right strategy for you: small files go
through a single request, files above 150 MiB are automatically streamed
through an upload session in chunks — without loading the file into memory:

```elixir
# Works the same for a 2 KB text file or a 40 GB backup
{:ok, metadata} = Magpie.Files.upload_file(client, "/Backup/db.dump", "priv/db.dump")

# Overwrite an existing file, with a custom chunk size
{:ok, _} =
  Magpie.Files.upload_file(client, "/Backup/db.dump", "priv/db.dump",
    mode: "overwrite",
    chunk_size: 16 * 1024 * 1024
  )
```

If you need manual control over the session (e.g. the data is generated on
the fly), use the lower-level primitives:

```elixir
{:ok, %{"session_id" => sid}} = Magpie.Files.UploadSession.start_data(client, chunk1)
{:ok, _} = Magpie.Files.UploadSession.append_data(client, sid, byte_size(chunk1), chunk2)

{:ok, metadata} =
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

# A whole folder as a zip
{:ok, %{body: zip}} = Magpie.Files.download_zip(client, "/Backup")
File.write!("backup.zip", zip)

# Or hand out a short-lived direct link instead
{:ok, %{"link" => url}} = Magpie.Files.get_temporary_link(client, "/Backup/db.dump")
```

## Listing folders lazily

`Magpie.Files.ListFolder.stream/2` hides cursor pagination behind a regular
`Stream` — pages are only fetched as you consume it:

```elixir
# All PDF names in a folder, no matter how many pages Dropbox returns
client
|> Magpie.Files.ListFolder.stream("/Documents")
|> Stream.filter(&String.ends_with?(&1["name"], ".pdf"))
|> Enum.map(& &1["name"])

# Lazy: only fetches as many pages as needed for the first 10 entries
client |> Magpie.Files.ListFolder.stream("/Photos") |> Enum.take(10)
```

The same pattern is available for searches, shared folders and file
requests — and `Magpie.Pager.stream/3` lets you wrap any other paginated
endpoint yourself:

```elixir
client |> Magpie.Files.search_stream("invoice", %{"path" => "/Work"}) |> Enum.to_list()
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
  {:ok, %{"metadata" => metadata}} ->
    metadata

  {:error, %Magpie.Error{status: 409, summary: "path/conflict" <> _}} ->
    :already_exists

  {:error, error} ->
    # Magpie.Error is an exception — raise it when you cannot handle it
    raise error
end
```

Paginated streams raise `Magpie.Error` instead, since a `Stream`
cannot return a tuple mid-enumeration.

## Testing your app

Magpie's requests can be routed to [`Req.Test`](https://hexdocs.pm/req/Req.Test.html)
stubs, so your test suite never touches the network. In `config/test.exs`:

```elixir
config :magpie, req_options: [plug: {Req.Test, Magpie}]
```

Then stub responses per test:

```elixir
test "lists the backup folder" do
  Req.Test.stub(Magpie, fn conn ->
    Req.Test.json(conn, %{"entries" => [%{"name" => "db.dump"}]})
  end)

  assert {:ok, %{"entries" => [_]}} = MyApp.Backups.list()
end
```
