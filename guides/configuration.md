# Configuration and diagnostics

## Configuring a client

Pass settings when you create a client. They apply to that client only.

```elixir
client = Magpie.Client.new("ACCESS_TOKEN",
  req_options: [receive_timeout: 15_000, connect_options: [timeout: 5_000]],
  retry: [max_retries: 2, log_level: false],
  timeout: 60_000
)
```

Use `Client.with_options/2` to derive another client, or `request: [...]` to
change settings for a single Storage call:

```elixir
fast_client = Magpie.Client.with_options(client, timeout: 5_000, retry: false)

Magpie.Storage.stat(client, "/report.pdf",
  request: [timeout: 2_000, retry: false])
```

Neither call changes `client`. All Storage functions accept `:request`. With
lower-level modules such as `Magpie.Files`, pass a derived client instead.

Settings are applied in this order: **operation → client → application → defaults**.
`:req_options` merges by key. Nested values such as `:headers` and
`:connect_options` are replaced, not merged recursively. A `:retry` policy also
replaces the previous policy. Endpoint headers and the token provider's bearer
token take precedence over custom headers.

Application defaults still work:

```elixir
config :magpie,
  req_options: [receive_timeout: 15_000],
  retry: [max_retries: 3, log_level: :warning],
  timeout: :infinity
```

Magpie reads these defaults when building each request. Avoid changing them to
switch between accounts; keep account settings on the client.

To override endpoint URLs, use `:base_url` for RPC calls, `:upload_url` for
content calls and `:notify_url` for `/files/list_folder/longpoll`, which Dropbox
serves from its own host. These client options take precedence over
`req_options[:base_url]`.
The older Req override still works when neither client option is set.

## Timeouts and retries

`:timeout` is an execution budget in milliseconds. The default is `:infinity`.
A Storage call shares one deadline across its requests, including metadata checks,
upload-session chunks and listing pages. For a stream, the clock starts when
enumeration starts and includes time spent processing entries. Each enumeration
starts a new budget.

In a batch, each item gets its own request budget. The existing batch `:timeout`
is still a task timeout. Direct calls to lower-level modules get a budget per
HTTP request.

Magpie checks the deadline before authentication, before sending, before refreshing
an expired token and after receiving the result. It also limits Req's pool,
receive and response timeouts to the remaining time. When a deadline check fails,
Storage returns `{:error, %Magpie.TimeoutError{}}`; bang functions and streams
raise. A shorter Req timeout can return `%Req.TransportError{}` first.

The budget does not interrupt callbacks, token-provider calls, local I/O, socket
connection establishment or custom adapters. Configure connection timeouts and
token providers separately. Response timeouts also depend on the protocol; see
[Req.Finch](https://hexdocs.pm/req/Req.Finch.html). Magpie does not kill the calling
process, so download cleanup can remove the temporary file and preserve the old
destination.

If a retry's delay would use up the remaining budget, Magpie returns the last
failure without waiting. On 429/503 responses, it uses `Retry-After`; otherwise
it uses exponential backoff with jitter. To choose the delay yourself:

```elixir
client = Magpie.Client.with_options(client,
  retry: [max_retries: 2, delay: fn count -> 500 * (count + 1) end])
```

`max_retries: 2` allows three attempts in total. `retry: false` disables transient
retries. The one-time replay after refreshing an expired token is separate.
Mutations and downloads streamed to disk do not retry transient failures
automatically. After a write times out, check the remote result before repeating
it: Dropbox may already have accepted it.

## OAuth requests

A supervised token server has its own HTTP settings:

```elixir
children = [
  {Magpie.Auth.TokenServer,
   name: MyApp.BackupTokens,
   app_key: System.fetch_env!("DROPBOX_APP_KEY"),
   app_secret: System.fetch_env!("DROPBOX_APP_SECRET"),
   refresh_token: System.fetch_env!("DROPBOX_REFRESH_TOKEN"),
   req_options: [receive_timeout: 10_000]}
]

client = Magpie.Client.new(
  token_provider: {Magpie.Auth.TokenServer, MyApp.BackupTokens},
  req_options: [receive_timeout: 30_000])
```

Here, token requests use a 10-second receive timeout and file requests use
30 seconds. Changing the client does not reconfigure its token server.

When `Client.new(refresh_token: ...)` starts the server for you, pass
`oauth_req_options: [...]` for token requests and `req_options: [...]` for file
requests. `Auth.exchange_code/3` and `Auth.refresh/3` also accept `:req_options`.
These settings override global Req options.

## Diagnosing failures

Normal Storage calls return expected API, transport, timeout and local-file
failures as error tuples. Invalid options raise `ArgumentError`. Exceptions from
application callbacks also raise. Batches catch per-item failures, but reject
invalid common options before starting any work.

API errors include `:endpoint`, `:attempts` and `:retry_after`, alongside the
existing `:status`, `:request_id`, `:summary` and `:body`. `retry_after` is in
milliseconds, or nil when unavailable. `attempts` includes an authentication replay.

For logs, `Error.diagnostics/1` leaves out the response body and summary:

```elixir
require Logger

case Magpie.Storage.stat(client, "/report.pdf") do
  {:ok, metadata} -> {:ok, metadata}
  {:error, %Magpie.Error{} = error} ->
    details = Magpie.Error.diagnostics(error)
    Logger.warning("Dropbox request failed", Map.to_list(details))
    {:error, error}
  {:error, exception} -> {:error, exception}
end
```

You can still read `body` and `summary` when handling an error. Avoid logging them
without checking their contents.

If your app knows the granted scopes, store them on the client:

```elixir
client = Magpie.Client.with_options(client, scopes: ["files.content.read"])
Magpie.Client.missing_scopes(client, ["files.content.write"])
# => ["files.content.write"]
```

Without a scope list, the result is `:unknown`. This check does not contact Dropbox
or infer permissions from a token. For a server-side `missing_scope` error,
`Error.required_scope/1` returns the permission Dropbox requested.

Use `account_id: "backup"` on a client to label its request Telemetry events.
This label does not select a Dropbox team member or namespace. Stop events include
`:attempts` and `:retry_after`; retry measurements include `:delay` in milliseconds.
Keep credentials out of labels.

## Writing files

The default remains `mode: "add", autorename: true`. Repeating a put can create
another file under a different name. Choose options to match the write you want:

| Write | Options |
|---|---|
| Add with automatic renaming | Defaults |
| Add without automatic renaming | `mode: "add", autorename: false` |
| Replace contents | `mode: "overwrite", autorename: false` |
| Update a known revision | `if_rev: revision` |
| Skip equal contents | `skip_unchanged: true` on file/binary sources |

`if_rev` takes precedence over `mode` and always sends a conditional write, even
with `skip_unchanged: true`. A metadata check cannot enforce the revision at the
moment the file is written.

Storage rejects unsupported or duplicate options and invalid values before I/O.
Chunk sizes must be positive and at most 150 MiB. The session threshold may be
zero but cannot exceed 150 MiB. The high-level Files upload helpers validate their
options too. For Dropbox fields that Storage does not expose, use the corresponding
lower-level endpoint function.
