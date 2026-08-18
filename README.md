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
    {:magpie, "~> 0.3"}
  ]
end
```

No configuration is required. Endpoint URLs and extra `Req` options can be
set with `config :magpie, ...` — see the `Magpie` module docs.

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

{:ok, account} = Magpie.Users.current_account(client)
{:ok, %{"entries" => entries}} = Magpie.Files.ListFolder.list_folder(client, "/Photos")
{:ok, metadata} = Magpie.Files.upload_file(client, "/Backup/report.pdf", "priv/report.pdf")
{:ok, %{body: contents}} = Magpie.Files.download(client, "/Backup/report.pdf")
```

Every call returns `{:ok, result}` on success or `{:error, %Magpie.Error{}}`
on API errors — with the HTTP `status`, Dropbox's `error_summary` and the
full error `body`.

## Features

- **Complete coverage** — all current user-scoped routes of the Dropbox API
  v2 (`files`, `sharing`, `file_properties`, `file_requests`, `users`,
  `account`, `auth`, `check`, `contacts`, `openid`), verified against the
  official [dropbox-api-spec](https://github.com/dropbox/dropbox-api-spec).
  Dropbox Business (`/team/*`) routes are out of scope.
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

- [Examples](https://magpie.hexdocs.pm/examples.html) — recipes for uploads,
  downloads, lazy listing, batch jobs, shared links, file requests, error
  handling and testing your app
- [OAuth 2 & token refresh](https://magpie.hexdocs.pm/oauth.html) — getting a
  refresh token, the web redirect flow, PKCE, running the token server,
  persisting tokens and custom providers
- [Phoenix & LiveView uploads](https://magpie.hexdocs.pm/phoenix.html) —
  controllers, `UploadWriter`, direct browser → Dropbox uploads

## Roadmap

Planned work — typed metadata structs, webhooks, a folder watcher, streaming
downloads and more — is tracked in
[ROADMAP.md](https://github.com/alexcassol/magpie/blob/main/ROADMAP.md).
Suggestions and PRs are welcome — open an
[issue](https://github.com/alexcassol/magpie/issues).

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
