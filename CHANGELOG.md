# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `Magpie.Storage.list/3` now returns Req transport failures as
  `{:error, exception}` instead of crashing the caller

### Documentation

- Added a complete `Magpie.Storage` workflow to the examples guide

## [0.5.0] - 2026-09-06

Storage ergonomics. Applications can now use Dropbox through a compact,
object-storage-style API while the complete Dropbox-specific surface remains
available under `Magpie.Files` and the other namespace modules.

### Added

- `Magpie.Storage` with `put`, `get`, streaming `download`, `delete`,
  `exists?`, `stat`, eager `list`, lazy `stream`, temporary download URLs and
  one-use upload URLs
- Explicit upload sources: `{:file, path}`, `{:binary, iodata}` and
  `{:stream, enumerable}`; streams use upload sessions and are rechunked
  without accumulating the whole input in memory
- Bang variants for storage operations, convenient for scripts
- `Magpie.Files.upload_data/4`, `upload_stream/4` and `download_file/3`
- `Magpie.Error.not_found?/1`, `conflict?/1`, `rate_limited?/1`, `auth?/1`
  and `retryable?/1`

### Changed

- Large file uploads now send their final partial chunk with the upload
  session commit request
- The public roadmap and its README link were removed

## [0.4.0] - 2026-09-04

Typed metadata. The `files` endpoints now describe files and folders with
structs instead of raw JSON maps with `".tag"` keys. This changes the shape
of several results — the [Upgrading to 0.4](guides/upgrading.md) guide lists
every affected call with the 0.3 and 0.4 versions side by side.

### Added

- `Magpie.FileMetadata`, `Magpie.FolderMetadata` and `Magpie.DeletedMetadata`
  — typed structs for the three kinds of entry Dropbox returns, with
  `DateTime` timestamps (`client_modified`, `server_modified`), a first-class
  `content_hash`, `is_downloadable` defaulting to `true`, and the nested
  objects (`sharing_info`, `media_info`, `file_lock_info`, ...) kept as raw
  maps
- `Magpie.Metadata` — the decoder behind it: `decode/2` (by `".tag"`, or by
  an explicit `:file`/`:folder` kind for the endpoints Dropbox answers
  untagged), `unwrap/2` for `%{"metadata" => ...}` results, `decode_page/2`
  for listings and `decode_matches/1` for search pages, so endpoints called
  by hand through `Magpie.post/3` can be decoded the same way
- `Magpie.Metadata.content_hash/1` — computes Dropbox's block-wise SHA-256
  content hash of a binary or a stream of chunks, to verify uploads and
  downloads against `Magpie.FileMetadata.content_hash`
- Upgrading guide on HexDocs

### Changed

- **Breaking:** `Magpie.Files.get_metadata/5`, `upload/6`, `upload_file/4`,
  `restore/3`, `Magpie.Files.UploadSession.finish/8` and `finish_data/5`
  return metadata structs instead of maps; `Magpie.LiveView.UploadWriter`'s
  `meta/1` carries the struct under `:metadata`
- **Breaking:** `Magpie.Files.create_folder/2`, `delete_folder/2`, `copy/3`
  and `move/3` return the struct directly — the `%{"metadata" => ...}`
  envelope is gone
- **Breaking:** `Magpie.Files.ListFolder.list_folder/3`,
  `list_folder_continue/2`, `stream/3` and `list_revisions/4` decode every
  entry; the page itself (`"cursor"`, `"has_more"`, `"is_deleted"`) keeps
  its string keys
- **Breaking:** `Magpie.Files.search/3`, `search_continue/2` and
  `search_stream/3` decode each match's `"metadata"` into a struct,
  flattening Dropbox's one-variant `%{".tag" => "metadata", "metadata" => ...}`
  union
- Req requirement bumped to `~> 0.7.4`, and `jason` — which Magpie always
  used to build the `Dropbox-API-Arg` header — is now a declared dependency
  instead of one inherited from Req

### Deprecated

- `Magpie.Files.create_folder_to_struct/2`, `delete_folder_to_struct/2` and
  the `Magpie.Folder` struct they build — `create_folder/2` and
  `delete_folder/2` return the richer typed metadata themselves now

## [0.3.2] - 2026-08-18

### Added

- Phoenix & LiveView uploads guide on HexDocs — controllers,
  `Magpie.LiveView.UploadWriter`, direct browser → Dropbox uploads with
  `presign_upload/4`, and how to test both offline
- `ROADMAP.md` — planned work moved out of the README

## [0.3.1] - 2026-08-14

Tracks the June–July 2026 Dropbox API spec updates that touch routes
Magpie already wraps.

### Added

- `Magpie.Files.ListFolder.list_folder/3` and `stream/3` now take an
  optional `opts` map merged into the request body, so callers can use
  the remaining `/files/list_folder` arguments — including the new
  `include_restorable_info` flag (each returned deleted entry then says
  whether it can be restored via `is_restorable`)
- `Magpie.Files.ListFolder.list_revisions/4` gained the same optional
  `opts` map (`"mode"`, `"before_rev"`, `"include_restorable_info"`)

### Changed

- `Magpie.Files.get_thumbnail_v2/3` docs no longer list `"quality"` as an
  option — Dropbox pulled the field from the public API surface in the
  July 2026 spec update

## [0.3.0] - 2026-08-10

Phoenix uploads. LiveView already owns the upload experience, so Magpie
does not ship a component — it fills the two gaps a Dropbox backend
creates: getting the bytes there without spooling them to disk, and
skipping the server altogether.

### Added

- `Magpie.LiveView.UploadWriter` — a `Phoenix.LiveView.UploadWriter` that
  streams a LiveView upload straight into a Dropbox upload session, so the
  bytes never land on the server's disk. Chunks are buffered to
  `:chunk_size` (default 8 MiB, Dropbox wants multiples of 4 MiB) and the
  tail rides along with the finish call. Magpie does not depend on
  `:phoenix_live_view` — the behaviour is a plain set of callbacks
- `Magpie.LiveView.presign_upload/4` — a LiveView `:external` uploader that
  mints a one-time link with `Magpie.Files.get_temporary_upload_link/3` so the
  browser posts the file straight to Dropbox, bypassing the server. Entries
  above Dropbox's 150 MB single-request limit are rejected at presign time
  instead of being handed a link that cannot work. The client-side half ships
  as `priv/static/magpie_uploader.js`

## [0.2.1] - 2026-08-05

### Added

- `Magpie.Auth.TokenServer` no longer requires a refresh token at startup.
  A server started without one sits in an *unconfigured* state — calls
  return a pattern-matchable
  `{:error, %Magpie.Error{summary: "no_refresh_token"}}` without touching
  the network — and the new `set_refresh_token/3` configures it (or
  replaces the token, for re-authorization) at any time, discarding any
  cached access token unless a valid `access_token`/`expires_at` pair is
  seeded. Fresh installs whose token arrives through the OAuth callback now
  work from a plain static supervision tree
- `Magpie.Auth.authorize_url/2` accepts `extra_params:` (keyword list or
  map) for additional Dropbox authorization params such as
  `force_reapprove`, `locale`, `require_role` and `disable_signup`.
  Params the function already sets cannot be overridden — collisions raise
  `ArgumentError`

## [0.2.0] - 2026-08-05

OAuth 2 support. Dropbox access tokens expire after ~4 hours, so a static
token is not enough for anything that runs unattended — Magpie now handles
the whole flow and keeps tokens fresh on its own.

### Added

- `Magpie.Auth` — OAuth 2 flow helpers: `authorize_url/2` (offline access
  by default), `pkce_pair/0` and `pkce_challenge/1` for public apps,
  `exchange_code/3` and `refresh/3`
- `Magpie.Auth.Token` — token struct with an absolute `expires_at` computed
  from Dropbox's `expires_in`
- `Magpie.Auth.TokenProvider` — behaviour that decouples the client from
  where tokens live, with two implementations: `Magpie.Auth.StaticToken`
  and `Magpie.Auth.TokenServer`
- `Magpie.Auth.TokenServer` — supervised token holder that refreshes
  proactively (configurable `:refresh_margin`, default 300s), serializes
  concurrent refreshes into a single request, survives failed refreshes and
  can persist tokens through an `:on_refresh` callback
- `Magpie.Client.new/1` accepts a refresh token
  (`refresh_token:`/`app_key:` + `app_secret:` or `pkce: true`, starting a
  linked `TokenServer`) or an explicit `token_provider: {module, arg}`
- Transparent recovery from expired tokens: requests rejected with HTTP 401
  `expired_access_token` are refreshed and replayed once. Streamed upload
  bodies cannot be replayed and are not retried — the proactive refresh
  covers them
- OAuth guide on HexDocs: getting a refresh token from the App Console, the
  web redirect flow, PKCE, supervision, persistence and custom providers

### Changed

- `Magpie.Client` gained a `token_provider` field; `access_token` is kept
  and `Magpie.Client.new("ACCESS_TOKEN")` behaves exactly as before
- `Magpie.Error.new/2` uses the OAuth `error` field (e.g. `"invalid_grant"`)
  as the error `summary` when there is no `error_summary`

## [0.1.0] - 2026-08-01

First release of Magpie 🐦 — a modern, actively maintained Elixir client for
the Dropbox API v2, born as a rewrite of the unmaintained
[elixir_dropbox](https://hex.pm/packages/elixir_dropbox) package (see the
Origin section of the README).

### Added

- Coverage of **all 132 current user-scoped routes** of the Dropbox API v2
  (`files`, `sharing`, `file_properties`, `file_requests`, `users`,
  `account`, `auth`, `check`, `contacts`, `openid`), verified against the
  official [dropbox-api-spec](https://github.com/dropbox/dropbox-api-spec)
- `Magpie.Files.upload_file/4` — smart upload: single request for small
  files, chunked upload session for large ones, streamed from disk
- `Magpie.Pager` — lazy `Stream`-based pagination, with ready-made wrappers
  (`Magpie.Files.ListFolder.stream/2`, `Magpie.Files.search_stream/3`,
  `Magpie.Sharing.list_folders_stream/2`, `Magpie.FileRequests.stream/2`)
- `Magpie.Async.await/4` — waits for asynchronous batch jobs by polling the
  check endpoint with exponential backoff
- `Magpie.Error` — normalized error struct (and exception) carrying the HTTP
  `status`, Dropbox's `error_summary` and the full error `body`
- Offline test suite built on `Req.Test` (~94% line coverage) and a
  `config :magpie, req_options: [...]` hook so consumer apps can stub
  Dropbox in their own tests
- Examples guide on HexDocs

### Changed

- HTTP client migrated from HTTPoison/Poison to [Req](https://hexdocs.pm/req)/Jason
- Every call now returns `{:ok, result}` or `{:error, %Magpie.Error{}}`
- Deprecated Dropbox endpoints migrated to their current versions:
  `move_v2`, `search_v2` (+ `search/continue_v2`), `copy_batch_v2`
  (+ `check_v2`), `upload_session/finish_batch_v2` and
  `create_shared_link_with_settings`
- Default endpoint URLs are built in — consumer configuration is optional

### Fixed

- `Magpie.Files.upload/6` sent the file as JSON instead of raw bytes,
  breaking every upload since the Req migration
- `Magpie.Users.get_account_to_struct/2` always returned an error even on
  successful responses
- Paper `docs/users/list/continue` pointed to a nonexistent URL

### Deprecated

- The legacy `/paper/docs/*` wrappers (`Magpie.Paper.*`) remain for
  compatibility, but the whole Paper API is deprecated by Dropbox — prefer
  `Magpie.Files.Paper`

[Unreleased]: https://github.com/alexcassol/magpie/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/alexcassol/magpie/releases/tag/v0.5.0
[0.4.0]: https://github.com/alexcassol/magpie/releases/tag/v0.4.0
[0.3.2]: https://github.com/alexcassol/magpie/releases/tag/v0.3.2
[0.3.1]: https://github.com/alexcassol/magpie/releases/tag/v0.3.1
[0.3.0]: https://github.com/alexcassol/magpie/releases/tag/v0.3.0
[0.2.1]: https://github.com/alexcassol/magpie/releases/tag/v0.2.1
[0.2.0]: https://github.com/alexcassol/magpie/releases/tag/v0.2.0
[0.1.0]: https://github.com/alexcassol/magpie/releases/tag/v0.1.0
