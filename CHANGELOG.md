# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.0]: https://github.com/alexcassol/magpie/releases/tag/v0.1.0
