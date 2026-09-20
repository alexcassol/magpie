# Verified backup

A successful upload does not prove that a backup can be restored. This example
uploads a directory, records each file's revision and Dropbox content hash,
then downloads the snapshot into a temporary directory and checks every file.
Only after that drill succeeds does it publish `manifest.json`.

The resulting manifest is a restore recipe. It can serve scheduled exports,
customer archive bundles, or release artifacts that need a repeatable recovery
check.

## Run offline

From this repository:

```sh
cd examples/verified_backup
mix deps.get
mix test
MIX_ENV=test mix run demo.exs
```

No credentials are needed. The demo uses `Req.Test` to exercise the real Magpie
upload and download code. It creates a snapshot, restores it, then supplies
corrupt bytes and checks that the failed restore leaves no output directory.
Temporary files are removed afterward.

## Run against Dropbox

Use a Dropbox app with `files.metadata.read`, `files.content.read`, and
`files.content.write`. See the [OAuth guide](../../guides/oauth.md). App Folder
apps interpret these paths relative to the app's folder.

```sh
export DROPBOX_ACCESS_TOKEN='your-access-token'
mix backup create fixtures/source /MagpieBackups
```

For unattended runs, set `DROPBOX_REFRESH_TOKEN`, `DROPBOX_APP_KEY`, and
`DROPBOX_APP_SECRET` instead. The refresh token takes precedence when present.

The command creates a unique snapshot folder and prints its manifest path:

```text
/MagpieBackups/<snapshot-id>/manifest.json
```

Restore it into a destination that does not exist yet:

```sh
mix backup restore /MagpieBackups/<snapshot-id>/manifest.json tmp/restored
```

Replace `<snapshot-id>` with the value printed by `create`. Compare the restored
files with [`fixtures/source`](fixtures/source). A second restore to the same
destination fails with `:destination_exists`; it does not overwrite that copy.

## What gets verified

```text
local directory
    -> upload each file with verify: true
    -> build draft manifest
    -> download every recorded revision into a temporary directory
    -> compare size and content hash
    -> publish manifest.json
```

Each manifest entry contains:

```json
{
  "path": "reports/orders.csv",
  "rev": "00000000001",
  "size": 8,
  "content_hash": "<64-character Dropbox content hash>"
}
```

This is a shape illustration; real values come from the uploaded files. The
hash is Dropbox's block-based content hash, computed with
`Magpie.Metadata.content_hash/1`, rather than a plain SHA-256 of the file.
Remote object names hash the relative path; the original directory structure
lives in the manifest. Restores request `rev:...` instead of the current file
path, so a later remote edit does not silently change the selected contents.

A restore uses a private staging directory beside the requested destination.
It publishes that directory only after all files pass verification. A failure
removes the staging directory, including any files already downloaded.
Absolute paths, `..`, symlinks, duplicate paths, and file/directory collisions
are rejected. Use a destination parent owned by the restoring process; this
example does not coordinate with other processes writing to the same directory.

## Retention without surprises

Keep the newest three completed snapshots:

```sh
mix backup retention /MagpieBackups 3
```

This prints three lists: `keep`, `delete_candidates`, and `incomplete`. It
**does not delete anything**. Review candidates and apply your own retention
policy separately. The newest snapshot is always kept when `KEEP` is at least
one. A missing or invalid manifest puts a folder in `incomplete`; an API failure
such as missing permission stops the plan rather than treating it as absence.

A failed upload or drill leaves a remote folder without a manifest. It is not
a completed snapshot. Retrying `create` uses a new folder, so partial uploads
cannot be mistaken for a successful retry. Inspect incomplete folders before
removing them. Do not run retention while creating snapshots if you need a
stable inventory.

## Read and adapt the code

- [`lib/verified_backup.ex`](lib/verified_backup.ex): directory traversal,
  verified uploads, manifest validation, restore drill, and retention plan.
- [`lib/mix/tasks/backup.ex`](lib/mix/tasks/backup.ex): three CLI commands.
- [`test/verified_backup_test.exs`](test/verified_backup_test.exs): corruption,
  staging cleanup, unsafe paths, existing destinations, and incomplete snapshots.

Use a quiesced export directory or a database dump. Walking a live directory
is not an application-consistent snapshot: files can change between uploads.
The example stores regular-file contents and relative paths. It does not
preserve empty directories, permissions, ownership, timestamps, or symlinks.
Uploads and the restore drill run sequentially and need enough local disk
space for a complete restored copy. Magpie handles chunked uploads and streamed
downloads when files are large.

Keep manifests in an app-owned folder. Hashes detect damaged or mismatched
content; they do not authenticate a manifest an attacker can replace. Dropbox
revision availability also depends on the account's history and deletion
policy. This example is not immutable storage or a replacement for an
independent backup copy. A drill proves byte recovery at that moment; add your
own application checks, such as opening an exported database, before treating
the contents as usable.
