# Magpie 🐦

[![CI](https://github.com/alexcassol/magpie/actions/workflows/ci.yml/badge.svg)](https://github.com/alexcassol/magpie/actions/workflows/ci.yml)
[![Coverage Status](https://coveralls.io/repos/github/alexcassol/magpie/badge.svg?branch=master)](https://coveralls.io/github/alexcassol/magpie?branch=master)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Elixir client for the [Dropbox API v2](https://www.dropbox.com/developers/documentation/http/documentation), built on [Req](https://hexdocs.pm/req).

Like the bird, Magpie collects and stashes your things — in your Dropbox.

## Installation

Add `magpie` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:magpie, git: "https://github.com/alexcassol/magpie.git"}
  ]
end
```

> Publishing to Hex is planned; once published this becomes `{:magpie, "~> 0.1"}`.

No configuration is required. The Dropbox endpoints can be overridden (rarely needed), and extra `Req` options can be merged into every request:

```elixir
config :magpie,
  base_url: "https://api.dropboxapi.com/2",
  upload_url: "https://content.dropboxapi.com/2/",
  req_options: []
```

## Usage

```elixir
client = Magpie.Client.new("DROPBOX_ACCESS_TOKEN")

# Who am I?
Magpie.Users.current_account(client)

# List a folder
{:ok, %{"entries" => entries}} = Magpie.Files.ListFolder.list_folder(client, "/Photos")

# Create a folder
{:ok, %{"metadata" => folder}} = Magpie.Files.create_folder(client, "/Backup")

# Upload a file
Magpie.Files.upload(client, "/Backup/report.pdf", "priv/report.pdf")

# Download a file
%{body: contents} = Magpie.Files.download(client, "/Backup/report.pdf")
```

Successful calls return `{:ok, body}`; API errors return `{{:status_code, code}, body}`.

## High-level flows

Magpie automates the multi-endpoint dances the Dropbox API expects from you
(see the [Examples guide](guides/examples.md) for more):

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

## Origin

Magpie started as a fork of [sger/elixir_dropbox](https://hex.pm/packages/elixir_dropbox), which is no longer maintained (its GitHub repository has been deleted). The code has since been modernized: HTTPoison/Poison were replaced with Req/Jason, and the test suite was rewritten with Req.Test. Credit and thanks to the original Elixir Dropbox contributors.

## License

MIT — see [LICENSE](LICENSE).
