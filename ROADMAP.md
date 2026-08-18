# Roadmap

Magpie already covers every user-scoped route of the Dropbox API v2. The focus
now is on the client-side ergonomics that real applications need — including a
few things the official SDKs never shipped.

Shipped versions are detailed in the [CHANGELOG](CHANGELOG.md). Suggestions
and PRs are welcome — open an
[issue](https://github.com/alexcassol/magpie/issues).

## 0.2.0 — OAuth 2 & token refresh ✅

- [x] `Magpie.Auth` — authorization URL builder, PKCE helpers, code-for-token exchange
- [x] Automatic access-token refresh (proactive, with margin, and reactive on
      `expired_access_token`) with single-flight guarantees
- [x] `Magpie.Auth.TokenProvider` behaviour + supervised `TokenServer`, so apps
      can plug their own token persistence
- [x] OAuth guide (Dropbox deprecated long-lived tokens — this makes Magpie
      production-ready for 24/7 applications)

## 0.2.1 — TokenServer ergonomics ✅

- [x] `TokenServer` can start without a refresh token and receive one at runtime
      (`set_refresh_token/3`) — plain static supervision trees, no DynamicSupervisor
      dance for apps that obtain tokens via OAuth callback
- [x] `authorize_url/2` `extra_params:` passthrough (`force_reapprove`, `locale`, …)

## 0.3.0 — Phoenix uploads ✅

- [x] `Magpie.LiveView.UploadWriter` — stream a LiveView upload straight into a
      Dropbox upload session, without spooling it to the server's disk
- [x] `Magpie.LiveView.presign_upload/4` — direct browser → Dropbox uploads via
      `get_temporary_upload_link/3`, so the bytes bypass your server entirely,
      with the JS uploader entry shipped in `priv/static`

## 0.4.0 — Typed metadata

- [ ] Decode API responses into structs (`Magpie.FileMetadata`,
      `Magpie.FolderMetadata`, `Magpie.DeletedMetadata`) with proper types —
      `DateTime` timestamps, first-class `content_hash` — instead of raw maps
      with `".tag"` keys

## 0.5.0 — Reacting to changes

- [ ] `Magpie.Webhook` — what the official SDKs never shipped: verification
      challenge handling, constant-time `X-Dropbox-Signature` HMAC validation,
      notification payload parsing, and a drop-in `Magpie.Webhook.Plug` for
      Phoenix (raw-body aware)
- [ ] `Magpie.Watcher` — supervised process wrapping `list_folder/longpoll`
      (cursor management, backoff, reconnection) that delivers folder change
      events as messages — "when a file lands in `/Inbox`, trigger a pipeline"
- [ ] Webhook → Watcher integration: use webhook notifications as the wake-up
      signal and `list_folder/continue` to fetch what actually changed

## Backlog

- [ ] Streaming download to disk (`download_file/3` mirroring `upload_file/4`,
      without loading the file into memory)
- [ ] Dropbox `content_hash` helper — verify integrity after transfers and skip
      uploads of unchanged files (`verify: true` / `skip_unchanged: true`)
- [ ] Rate-limit aware retries — honor `Retry-After` on 429/503 out of the box
- [ ] `:telemetry` events for every request
- [ ] `Dropbox-API-Path-Root` support — access team space namespaces, not just
      the member folder
- [ ] `upload_many/3` — concurrent multi-file upload via upload session batches

## Out of scope

Magpie is a client library — application-level workflows (retention policies,
deduplication, sync) are intentionally out of scope, though the guides include
recipes for building them on top. Dropbox Business (`/team/*`) routes are not
planned either.
