# Magpie 🐦

[![Hex.pm](https://img.shields.io/hexpm/v/magpie.svg)](https://hex.pm/packages/magpie)
[![Hexdocs](https://img.shields.io/badge/hexdocs-magpie-purple.svg)](https://hexdocs.pm/magpie)
[![CI](https://github.com/alexcassol/magpie/actions/workflows/ci.yml/badge.svg)](https://github.com/alexcassol/magpie/actions/workflows/ci.yml)
[![Coverage Status](https://coveralls.io/repos/github/alexcassol/magpie/badge.svg?branch=main)](https://coveralls.io/github/alexcassol/magpie?branch=main)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Elixir client for the [Dropbox API v2](https://www.dropbox.com/developers/documentation/http/documentation), built on [Req](https://hexdocs.pm/req).

Like the bird, Magpie collects and stashes your things — in your Dropbox.

## Installation

Add `magpie` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:magpie, "~> 0.2"}
  ]
end
```

No configuration is required. The Dropbox endpoints can be overridden (rarely needed), and extra `Req` options can be merged into every request:

```elixir
config :magpie,
  base_url: "https://api.dropboxapi.com/2",
  upload_url: "https://content.dropboxapi.com/2/",
  req_options: []
```

## Usage

```elixir
# A static access token — fine for scripts, but Dropbox expires it in ~4h
client = Magpie.Client.new("DROPBOX_ACCESS_TOKEN")

# A refresh token — Magpie mints access tokens as needed, so this client
# keeps working forever (see the OAuth guide)
client =
  Magpie.Client.new(
    refresh_token: System.fetch_env!("DROPBOX_REFRESH_TOKEN"),
    app_key: System.fetch_env!("DROPBOX_APP_KEY"),
    app_secret: System.fetch_env!("DROPBOX_APP_SECRET")
  )

# Who am I?
Magpie.Users.current_account(client)

# List a folder
{:ok, %{"entries" => entries}} = Magpie.Files.ListFolder.list_folder(client, "/Photos")

# Create a folder
{:ok, %{"metadata" => folder}} = Magpie.Files.create_folder(client, "/Backup")

# Upload a file
Magpie.Files.upload(client, "/Backup/report.pdf", "priv/report.pdf")

# Download a file
{:ok, %{body: contents}} = Magpie.Files.download(client, "/Backup/report.pdf")
```

Every call returns `{:ok, result}` on success or `{:error, %Magpie.Error{}}` on API errors — with the HTTP `status`, Dropbox's `error_summary` and the full error `body`.

## OAuth 2 & token refresh

Dropbox stopped issuing long-lived access tokens: they expire after about four hours. Magpie handles the whole OAuth 2 flow and keeps tokens fresh on its own — proactively before they expire, and by replaying the request if Dropbox rejects one anyway. Concurrent requests never trigger parallel refreshes.

```elixir
# Build the authorization URL (PKCE optional, offline access by default)
{verifier, challenge} = Magpie.Auth.pkce_pair()
Magpie.Auth.authorize_url(app_key, redirect_uri: callback_url, code_challenge: challenge)

# Exchange the code Dropbox sent back for a refresh token
{:ok, token} = Magpie.Auth.exchange_code(app_key, code, code_verifier: verifier)

# Keep a supervised token holder, and build clients from it
children = [
  {Magpie.Auth.TokenServer,
   name: MyApp.DropboxToken,
   app_key: app_key,
   app_secret: app_secret,
   refresh_token: token.refresh_token}
]

client = Magpie.Client.new(token_provider: {Magpie.Auth.TokenServer, MyApp.DropboxToken})
```

Tokens can live wherever you want — implement `Magpie.Auth.TokenProvider` and pass `token_provider: {MyProvider, arg}`. See the [OAuth guide](https://magpie.hexdocs.pm/oauth.html).

## High-level flows

Magpie automates the multi-endpoint dances the Dropbox API expects from you
(see the [Examples guide](https://magpie.hexdocs.pm/examples.html) for more):

```elixir
# Smart upload: single request for small files, chunked upload session for
# big ones — streaming from disk, picked automatically
{:ok, _} = Magpie.Files.upload_file(client, "/Backup/db.dump", "priv/db.dump")

# Lazy pagination: cursors and /continue calls hidden behind a Stream
client
|> Magpie.Files.ListFolder.stream("/Photos")
|> Stream.filter(&(&1[".tag"] == "file"))
|> Enum.take(100)

# Async batch jobs: polling with exponential backoff
{:ok, launch} = Magpie.Files.MoveBatch.move_batch(client, entries)
{:ok, result} = Magpie.Async.await(client, launch, &Magpie.Files.MoveBatch.check/2)
```

## Covered endpoints

Magpie covers **all current user-scoped routes** of the Dropbox API v2 (132 routes as of August 2026), verified against the official [dropbox-api-spec](https://github.com/dropbox/dropbox-api-spec):

- **files** — upload (single and sessions, incl. batch), download, download_zip, export, copy/move/delete (incl. batches), list_folder (+ continue, cursor, longpoll), metadata, search, thumbnails, previews, temporary links and upload links, save_url, tags, locks, Paper-as-files
- **sharing** — shared links (create/modify/revoke/list/download), file members, folder members, full shared-folder lifecycle
- **file_properties** — property groups and templates (user- and team-owned)
- **file_requests** — create, get, update, list, count, delete
- **users** / **account** / **auth** / **check** / **contacts** / **openid**
- **paper** — legacy `/paper/docs/*` kept for compatibility (deprecated by Dropbox — prefer `Magpie.Files.Paper`)

Dropbox Business (`/team/*`) routes are out of scope.

## Testing

The test suite runs entirely offline using [`Req.Test`](https://hexdocs.pm/req/Req.Test.html) stubs — every endpoint wrapper is verified against the exact route it must hit, and the high-level flows are tested end-to-end:

```sh
mix test            # run the suite
mix coveralls       # run with coverage report (currently ~94% line coverage)
```

## Roadmap

Magpie already covers every user-scoped route of the Dropbox API v2. The focus
now is on the higher-level ergonomics that real applications need:

### 0.2.0 — OAuth 2 & token refresh ✅

- [x] `Magpie.Auth` — authorization URL builder, PKCE helpers, code-for-token exchange
- [x] Automatic access-token refresh (proactive, with margin, and reactive on
      `expired_access_token`) with single-flight guarantees
- [x] `Magpie.Auth.TokenProvider` behaviour + supervised `TokenServer`, so apps
      can plug their own token persistence
- [x] OAuth guide (Dropbox deprecated long-lived tokens — this makes Magpie
      production-ready for 24/7 applications)

### 0.3.0 — Change watching

- [ ] `Magpie.Watcher` — supervised process wrapping `list_folder/longpoll`
      (cursor management, backoff, reconnection) that delivers folder change
      events as messages — "when a file lands in `/Inbox`, trigger a pipeline"

### Backlog

- [ ] Streaming download to disk (`download_file/3` mirroring `upload_file/4`,
      without loading the file into memory)
- [ ] Dropbox `content_hash` helper — verify integrity after transfers and skip
      uploads of unchanged files (`verify: true` / `skip_unchanged: true`)
- [ ] Rate-limit aware retries — honor `Retry-After` on 429/503 out of the box
- [ ] `:telemetry` events for every request
- [ ] `upload_many/3` — concurrent multi-file upload via upload session batches

Suggestions and PRs are welcome — open an [issue](https://github.com/alexcassol/magpie/issues).


## Origin

Magpie started as a fork of [sger/elixir_dropbox](https://hex.pm/packages/elixir_dropbox), which is no longer maintained (its GitHub repository has been deleted). The code has since been modernized: HTTPoison/Poison were replaced with Req/Jason, and the test suite was rewritten with Req.Test. Credit and thanks to the original Elixir Dropbox contributors.

## License

MIT — see [LICENSE](LICENSE).
