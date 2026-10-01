# Incremental listings and webhooks

## Pages and saved cursors

`Storage.list/3` still returns all entries and `Storage.stream/3` still emits
entries lazily, raising on failures. For explicit checkpoints use
`Storage.list_page/3` and `Storage.continue_list/3`. They fetch one page and return
`{:ok, %Magpie.ListPage{entries: entries, cursor: cursor, has_more: boolean}}`
or `{:error, exception}`. No cursor is stored or acknowledged by Magpie.

```elixir
client = Magpie.Client.new("ACCESS_TOKEN")

{:ok, first} =
  Magpie.Storage.list_page(client, "", recursive: true, include_deleted: true, limit: 100)

Enum.each(first.entries, &IO.inspect/1)
# Only after processing every entry successfully:
saved_cursor = first.cursor
{:ok, next} = Magpie.Storage.continue_list(client, saved_cursor)
Enum.each(next.entries, &IO.inspect/1)
# Repeat while next.has_more; retain the final cursor for future changes.
```

`list_page` takes the listing keywords documented in `Storage.stream/3`:
`recursive`, `include_media_info`, `include_deleted`,
`include_has_explicit_shared_members`, `include_mounted_folders`, `limit`
(1–2000, a server hint), `shared_link`, `include_property_groups` and
`include_non_downloadable_files`. Defaults remain Dropbox's defaults.
Both new calls accept `request: [...]` for client/request overrides; continuation
accepts no listing flags because they are encoded in the cursor. Unsupported
options and empty/non-binary cursors raise `ArgumentError` before I/O.

Keep cursors with their account, namespace, path and original listing settings.
They are opaque strings, not timestamps. Even an empty terminal page has a new
checkpoint to save. A final cursor can later return more entries. The
[Dropbox change guide](https://docs.dropboxapi.com/dropbox-api/docs/detecting-changes)
explains cursor polling and expiry. API errors retain `Magpie.Error`, expected
transport failures retain Req exception types, and execution budgets return
`Magpie.TimeoutError`. Each call has its own execution budget; set an overall
worker deadline in your application if necessary.

Entries use the existing `FileMetadata`, `FolderMetadata` and `DeletedMetadata`
types. Apply file/folder state at the reported path; deletion removes the path
and descendants. Unknown future metadata tags remain maps. Do not infer an event
kind (create, edit, move) from one entry. This is state reconciliation, with no
complete event history or exactly-once delivery guarantee.

## Starting with future changes only

If existing entries are intentionally out of scope, request the latest cursor
with the same listing options instead of fetching and discarding every initial
page. This endpoint accepts the Dropbox `ListFolderArg` map, just like
`list_folder/3`; its options use string keys, unlike the Storage keywords.

<!-- executable-latest-cursor -->
```elixir
{:ok, %{"cursor" => cursor}} =
  Magpie.Files.ListFolder.get_latest_cursor(client, "", %{
    "recursive" => true,
    "include_deleted" => true
  })

# Persist this starting cursor externally; no initial entries are returned.
# Later, when polling or processing a webhook:
{:ok, page} = Magpie.Storage.continue_list(client, cursor)
# Apply page.entries before committing page.cursor; drain while page.has_more.
```

This deliberately skips the current contents. It does not create a local
snapshot and cannot replace full-listing recovery after a reset. Keep the cursor
with its account, namespace and options. `get_latest_cursor(client, path)` keeps
its original request and `{:ok, %{"cursor" => cursor}}` result.

## Scanner with external checkpoint storage

The following module is compiled directly from this guide by
`test/incremental_guide_test.exs`. `commit_page` is provided by your application:
it must apply the page and save its cursor atomically, returning `:ok` only once
both are durable. For nontransactional side effects use idempotency or an outbox.
The scanner holds only the current page and stops immediately on commit failure.

<!-- executable-scanner -->
```elixir
defmodule MagpieGuide.Scanner do
  alias Magpie.Storage

  def scan(client, root, saved_cursor, commit_page) do
    result =
      if saved_cursor do
        Storage.continue_list(client, saved_cursor)
      else
        Storage.list_page(client, root, recursive: true, include_deleted: true, limit: 100)
      end

    with {:ok, page} <- result,
         :ok <- commit_page.(page) do
      if page.has_more do
        scan(client, root, page.cursor, commit_page)
      else
        {:ok, page.cursor}
      end
    end
  end
end
```

An application worker loads its checkpoint **after acquiring exclusive ownership
of the account** and calls the scanner. Here `Store` is your storage interface,
not a Magpie service:

```elixir
defmodule MyApp.DropboxScan do
  def run(account) do
    MyApp.Store.with_account_lease(account, fn ->
      client = MyApp.DropboxClients.for_account(account)
      root = MyApp.Store.root(account)
      saved = MyApp.Store.cursor(account)
      MyApp.DropboxRecovery.run_locked(client, account, root, saved)
    end)
  end
end
```

Implement `with_account_lease/2` with a database lock or renewable distributed
lease covering the entire scan and rebuild. A process-local lock is insufficient
across nodes; a lease must fence stale workers and prevent old checkpoints from
overwriting newer ones. `apply_page_and_checkpoint/2` must roll back on failure.
Do not persist `page.cursor` when an entry fails. Retry from the last committed
cursor; repeated entries and duplicate deletion notifications must be harmless.
The runnable [document search example](https://github.com/alexcassol/magpie/tree/main/examples/document_search)
already demonstrates external SQLite cursors and transactional reconciliation
using the unchanged low-level endpoints.

## Recovery when Dropbox invalidates the cursor

A 409 with the top-level `reset` tag returns
`%Magpie.CursorError{reason: :reset, rebuild_required: true, error: api_error}`.
Dropbox does not tell you whether the cursor expired or was otherwise invalidated.
A `path` error or malformed request remains `Magpie.Error` and needs its own
handling. In particular, HTTP 400 on `continue_list` is not classified as an
invalid cursor: Dropbox may return plain text without a stable error tag, and
400 alone cannot distinguish cursor corruption from another request error.
Inspect diagnostics and the original payload and choose recovery explicitly.
This is a limitation; only a confirmed 409 `reset` triggers `CursorError`.
No recovery request is made automatically.

Rebuild a shadow snapshot from the same root/settings. Publish it and its final
cursor atomically only after all pages succeed, removing stale local entries
absent from the new snapshot. Keep the previous snapshot on failure. Under the
same account lease, an application can implement recovery as follows:

```elixir
defmodule MyApp.DropboxRecovery do
  def run_locked(client, account, root, saved) do
    case MagpieGuide.Scanner.scan(
           client,
           root,
           saved,
           &MyApp.Store.apply_page_and_checkpoint(account, &1)
         ) do
      {:error, %Magpie.CursorError{rebuild_required: true}} ->
        shadow = MyApp.Store.begin_shadow(account)

        try do
          with {:ok, final} <-
                 MagpieGuide.Scanner.scan(
                   client,
                   root,
                   nil,
                   &MyApp.Store.apply_shadow_page(shadow, &1)
                 ),
               :ok <- MyApp.Store.publish_shadow(account, shadow, final) do
            {:ok, final}
          end
        after
          MyApp.Store.discard_shadow(shadow)
        end

      result ->
        result
    end
  end
end
```

`apply_shadow_page/2` writes only the staging snapshot; `publish_shadow/3` swaps
snapshot and checkpoint together. `discard_shadow/1` cleans staging data without
deleting a published snapshot. These callbacks belong to the consumer.
Rebuilding recovers present state, not intermediate historical events.

## Phoenix/Plug webhook endpoint

Enable `files.metadata.read` and register your public HTTPS endpoint in the
Dropbox App Console. According to the
[official webhook contract](https://docs.dropboxapi.com/dropbox-api/docs/webhooks),
GET verification must echo `challenge` with `Content-Type: text/plain` and
`X-Content-Type-Options: nosniff`. POST notifications carry account IDs; their
HMAC-SHA256 signature uses the app secret and original request body. Dropbox
expects a response within ten seconds. Notifications may concern changes outside
your particular cursor's subfolder.

This complete standalone Plug endpoint also shows the order to use in your
Phoenix endpoint: put `Magpie.Webhook.Plug` **above `Plug.Parsers`**, so it owns
body reading and halts the matching request before any JSON parser. Phoenix
can use `json_decoder: Phoenix.json_library()` instead of Jason:

<!-- executable-endpoint -->
```elixir
defmodule MyApp.DropboxEndpoint do
  use Plug.Builder

  plug(Magpie.Webhook.Plug,
    path: "/webhooks/dropbox",
    app_secret: &MyApp.DropboxJobs.app_secret/0,
    notify: &MyApp.DropboxJobs.enqueue/1,
    max_body_bytes: 1_048_576
  )

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )
end
```

Use remote function captures for callbacks in compiled Plug pipelines; anonymous
functions cannot be escaped during compile-time initialization. Read secrets
at request time through the remote function, rather than embedding them in the
compiled endpoint.

The Plug reads original bytes in chunks and preserves them in
`conn.private[:magpie_webhook_raw_body]`. Do not place a body parser before it
or recreate the body with `Jason.encode!`. Plug remains a test-only dependency
of Magpie; Phoenix supplies it, or add `{:plug, "~> 1.15"}` to a standalone app.
There is no Phoenix dependency. The adapter returns 403 for missing/invalid or
duplicate signatures, 400 for malformed signed payloads/read failures, 413 for
oversized bodies, 503 for enqueue errors, and 200 after `notify` returns `:ok`.
Signed JSON objects without `list_folder` are acknowledged with 200 without
calling `notify`; the pure API returns `{:ok, :ignored}` and the Plug records
`:ignored` in `private[:magpie_webhook_notification]`. Observe these cases in the
application to discover unsupported formats. This is not Business/team support.
Empty account lists also receive 200 without invoking the callback. Recognized
but malformed `list_folder` notifications still receive 400.

Resolved secrets must be non-empty binaries. Invalid secret-function results and
unexpected `notify` returns raise explicit `ArgumentError` without including
returned values. This makes configuration/programming errors visible to the host
instead of disguising them as invalid signatures. Callback exceptions propagate
to the hosting application. Other paths pass through; unsupported methods on the webhook path return 405.

For another framework use `Magpie.Webhook.challenge/1` to obtain the response
map and `Magpie.Webhook.notification(raw_body, signature, app_secret)` to obtain
`{:ok, accounts}`, `{:ok, :ignored}` or
`{:error, :invalid_signature | :invalid_payload}`.
`valid_signature?/3` is available separately. Extra JSON fields are ignored;
`list_folder.accounts` must be a list of non-empty strings (empty is valid).
Order and duplicates are preserved. There is no replay protection in the
signature, nor a per-file event ID to deduplicate.

## Background processing, optionally with Oban

Your callback must durably enqueue all notified accounts quickly and return
`:ok`, or return `{:error, reason}` so the endpoint can signal failure. Do not
scan synchronously or return success for an unpersisted task. Repeated requests
can enqueue the same account; serialize account scans and make page writes
idempotent. Keep a periodic reconciliation job for missed notifications.

For an application that already has Oban installed, migrated and supervised,
configure a `dropbox` queue and use this recipe. These application modules are
integration templates; Magpie does not install Oban or a database:

```elixir
defmodule MyApp.DropboxJobs do
  def app_secret, do: System.fetch_env!("DROPBOX_APP_SECRET")

  def enqueue(accounts) do
    # MyApp.Repo must be the same repo configured for Oban.
    case MyApp.Repo.transaction(fn ->
           Enum.each(accounts, fn account ->
             case %{account: account} |> MyApp.DropboxWorker.new() |> Oban.insert() do
               {:ok, _job} -> :ok
               {:error, reason} -> MyApp.Repo.rollback(reason)
             end
           end)
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule MyApp.DropboxWorker do
  use Oban.Worker, queue: :dropbox, max_attempts: 10

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account" => account}}) do
    case MyApp.DropboxScan.run(account) do
      {:ok, _cursor} ->
        :ok

      {:error, %Magpie.Error{} = error} ->
        if Magpie.Error.not_found?(error), do: {:cancel, error}, else: {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

The transaction rolls back all inserts if any enqueue fails. Use the same Ecto
repo as Oban; inserts outside that transaction would not have this guarantee.
Repeated successful deliveries can still enqueue duplicates, so serialize scans
and apply pages idempotently. `DropboxScan.run/1` holds the account lease through
both scanning and recovery. Confirmed `not_found` errors cancel the job: the
application must resolve a removed root or configuration before rescheduling.
Other failures retain Oban retries. Tune permanent-error handling for your app.
Optional [Oban uniqueness](https://oban.hexdocs.pm/unique_jobs.html) can reduce duplicate
jobs but does not replace an account lock. Be careful coalescing notifications
while a worker is running: schedule another scan or keep a durable dirty marker
so changes near job completion are not lost. Consult
[Oban installation](https://oban.hexdocs.pm/Oban.html) for the consumer's setup.

## Offline consumer tests

Use per-client Req.Test configuration so no real credentials are involved.
This complete test is extracted and run by the library's suite:

<!-- executable-consumer-test -->
```elixir
defmodule MyApp.DropboxConsumerTest do
  use ExUnit.Case, async: true

  test "polls from an externally saved cursor" do
    client =
      Magpie.Client.new("fake-token", req_options: [plug: {Req.Test, __MODULE__}], retry: false)

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/2/files/list_folder/continue"
      assert Jason.decode!(Req.Test.raw_body(conn)) == %{"cursor" => "previous"}
      Req.Test.json(conn, %{"entries" => [], "cursor" => "saved", "has_more" => false})
    end)

    assert {:ok, page} = Magpie.Storage.continue_list(client, "previous")
    assert page.cursor == "saved"
  end
end
```

Build signed `Plug.Test.conn` requests with deliberately formatted raw JSON and
assert `private.magpie_webhook_raw_body` equals those exact bytes. Stub the
enqueue callback, assert it receives every account, and ensure failed signatures
never invoke it. See `test/webhook_test.exs` and the
[testing guide](testing.md) for ownership allowances when jobs run in another
process. Guide tests extract the scanner, recovery, account-leased scan, endpoint
and consumer test, plus the incremental snippet in the README. Fake application
stores exercise the full endpoint → queued account → leased scan → reset recovery
flow. Oban-specific inserts and worker code remain an integration recipe checked
against the official API; the default suite has no Oban or database dependency.
