# Magpie 🐦

[![Hex.pm](https://img.shields.io/hexpm/v/magpie.svg)](https://hex.pm/packages/magpie)
[![Hexdocs](https://img.shields.io/badge/hexdocs-magpie-purple.svg)](https://hexdocs.pm/magpie)
[![CI](https://github.com/alexcassol/magpie/actions/workflows/ci.yml/badge.svg)](https://github.com/alexcassol/magpie/actions/workflows/ci.yml)
[![Coverage Status](https://coveralls.io/repos/github/alexcassol/magpie/badge.svg?branch=main)](https://coveralls.io/github/alexcassol/magpie?branch=main)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Elixir client for the [Dropbox API v2](https://www.dropbox.com/developers/documentation/http/documentation), built on [Req](https://hexdocs.pm/req).

Like the bird, Magpie collects and stashes your things — in your Dropbox.

## Installation

```elixir
def deps do
  [
    {:magpie, "~> 0.6"}
  ]
end
```

No configuration is required. Endpoint URLs, retry controls and extra `Req`
options can be set with `config :magpie, ...` — see the `Magpie` module docs.

## Quick start

```elixir
# A refresh token keeps the client working indefinitely — Magpie mints
# access tokens as needed (see the OAuth guide)
client =
  Magpie.Client.new(
    refresh_token: System.fetch_env!("DROPBOX_REFRESH_TOKEN"),
    app_key: System.fetch_env!("DROPBOX_APP_KEY"),
    app_secret: System.fetch_env!("DROPBOX_APP_SECRET")
  )

# For a quick script, a static access token works too (Dropbox expires it in ~4h)
client = Magpie.Client.new("DROPBOX_ACCESS_TOKEN")

alias Magpie.Storage

{:ok, %Magpie.FileMetadata{size: size}} =
  Storage.put(client, "/Backup/report.pdf", {:file, "priv/report.pdf"}, verify: true)

{:ok, contents} = Storage.get(client, "/Backup/report.pdf")
{:ok, url} = Storage.url(client, "/Backup/report.pdf")

# Large downloads stream directly to disk instead of living in BEAM memory
{:ok, "tmp/report.pdf"} =
  Storage.download(client, "/Backup/report.pdf", "tmp/report.pdf", mkdir_p: true)
```

Every call returns `{:ok, result}` on success or an error tuple. Dropbox API
errors are `%Magpie.Error{}` values with the HTTP `status`, Dropbox's
`error_summary`, full `body` and `request_id`; expected transport failures are
also returned instead of raising from normal `Storage` calls. Files, folders
and deleted entries come back as
`Magpie.FileMetadata`, `Magpie.FolderMetadata` and `Magpie.DeletedMetadata`
structs:

```elixir
for %Magpie.FileMetadata{name: name, size: size, server_modified: at} <- entries do
  "#{name}: #{size} bytes, modified #{DateTime.to_date(at)}"
end
```

## Features

- **Simple storage API** — `Magpie.Storage` covers the common path with
  `put`, `get`, `download`, `delete`, `copy`, `move`, `mkdir`, `exists?`,
  `stat`, `list`, `stream`, concurrent batches and temporary URLs. Upload a
  local file, binary/iodata or arbitrary stream; verify content, skip unchanged
  objects, protect writes with `if_rev`, observe transfer progress, and stream
  large downloads atomically to disk.
- **Production reliability** — semantically safe Dropbox reads retry 429 and
  transient 5xx/transport failures with `Retry-After` or exponential backoff;
  mutating calls are never retried blindly. Telemetry covers request start,
  stop, exception and retry events.
- **Complete coverage** — all current user-scoped routes of the Dropbox API
  v2 (`files`, `sharing`, `file_properties`, `file_requests`, `users`,
  `account`, `auth`, `check`, `contacts`, `openid`), verified against the
  official [dropbox-api-spec](https://github.com/dropbox/dropbox-api-spec).
  Dropbox Business (`/team/*`) routes are out of scope.
- **Typed metadata** — the `files` endpoints decode Dropbox's metadata into
  structs with `DateTime` timestamps and a first-class `content_hash`, and
  `Magpie.Metadata.content_hash/1` computes the same hash locally to verify
  a transfer
- **OAuth 2 & token refresh** — authorization URL, PKCE, code exchange, and a
  supervised `Magpie.Auth.TokenServer` that keeps access tokens fresh
  (proactively, and on `expired_access_token`) with single-flight refreshes.
  Store tokens wherever you want by implementing `Magpie.Auth.TokenProvider`.
- **High-level flows** — `Magpie.Files.upload_file/4` picks single request or
  chunked upload session by size and streams from disk; `Magpie.Pager` hides
  cursor pagination behind a lazy `Stream`; `Magpie.Async.await/4` polls
  async batch jobs with exponential backoff.
- **Phoenix & LiveView uploads** — `Magpie.LiveView.UploadWriter` streams a
  LiveView upload straight into a Dropbox upload session (no disk spooling),
  and `Magpie.LiveView.presign_upload/4` lets the browser post directly to
  Dropbox. Magpie does not depend on `:phoenix_live_view`.
- **Offline testing** — route every request to `Req.Test` stubs with
  `config :magpie, req_options: [plug: {Req.Test, Magpie}]`.

## Documentation

The API reference lives on [HexDocs](https://hexdocs.pm/magpie), along with
the guides:

- [Examples](https://magpie.hexdocs.pm/examples.html) — the complete
  `Magpie.Storage` workflow plus recipes for lower-level uploads, downloads,
  lazy listing, batch jobs, shared links, error handling and testing your app
- [OAuth 2 & token refresh](https://magpie.hexdocs.pm/oauth.html) — getting a
  refresh token, the web redirect flow, PKCE, running the token server,
  persisting tokens and custom providers
- [Phoenix & LiveView uploads](https://magpie.hexdocs.pm/phoenix.html) —
  controllers, `UploadWriter`, direct browser → Dropbox uploads
- [Upgrading](https://magpie.hexdocs.pm/upgrading.html) — 0.6 additions and
  every 0.4 call whose result changed with typed metadata

## Development

The test suite runs entirely offline against `Req.Test` stubs:

```sh
mix test            # run the suite
mix coveralls       # run with coverage report
```

## Origin

Magpie started as a fork of [sger/elixir_dropbox](https://hex.pm/packages/elixir_dropbox),
which is no longer maintained. It has since been rewritten on top of
Req/Jason with a new offline test suite. Credit and thanks to the original
Elixir Dropbox contributors.

## License

MIT — see [LICENSE](LICENSE).
