# Document search

A team keeps policies, runbooks, and supplier notes in Dropbox. This application
builds a local search index of one chosen folder and its subfolders. Search
results include a matching excerpt, the Dropbox file ID, and the revision that
was actually indexed.

Magpie handles authentication, listings, and downloads. The application extracts
text and writes it to SQLite FTS5. You can search the saved index without a
network connection or Dropbox credentials.

## Run offline

This example needs Elixir 1.17 or later because of its SQLite dependency. It
uses the Magpie checkout at `../..`. Exqlite downloads a precompiled SQLite
binding where available; building it from source needs a C compiler and Make.
No separate database server is required.

```sh
cd examples/document_search
mix deps.get
mix test
MIX_ENV=test mix run demo.exs
```

The demo creates a temporary SQLite database and uses `Req.Test` for every
Dropbox request. It:

1. Indexes a travel policy and an on-call handbook across two listing pages.
2. Searches for `train reimbursement` and prints a matching excerpt.
3. Closes and reopens the database, then resumes the saved cursor.
4. Indexes a moved, revised policy and removes the deleted handbook.
5. Searches for the new policy wording and checks that obsolete text is gone.

The database is removed afterward. The tests use real SQLite queries, rather
than a fake search service.

## Index a Dropbox folder

Create `/Knowledge` in your Dropbox app's accessible space and copy the files
from [`fixtures`](fixtures) into it. An App Folder app interprets `/Knowledge`
relative to that app's folder.

The token needs `account_info.read`, `files.metadata.read`, and
`files.content.read`. The example only reads Dropbox. See the
[OAuth guide](../../guides/oauth.md) for token setup.

```sh
export DROPBOX_ACCESS_TOKEN='your-access-token'
mix search sync /Knowledge
mix search query 'train reimbursement'
mix search query 'database incident'
mix search status
```

For scheduled syncs, set `DROPBOX_REFRESH_TOKEN`, `DROPBOX_APP_KEY`, and
`DROPBOX_APP_SECRET` instead. A refresh token takes precedence when present.

Edit a document or move it into a subfolder in Dropbox, then run `sync` again.
The indexer continues from its saved cursor. An unchanged revision can reuse
its extracted text when the file's path changes. A changed revision is
downloaded using `rev:...`, then checked against the listed size and Dropbox
content hash before extraction.

Use one database per Dropbox app, account, and selected root. The account ID and root are
stored in SQLite; trying to reuse it for another scope fails, including with
`--rebuild`. For another folder, choose another index file:

```sh
mix search sync /SupplierDocuments --index var/suppliers.sqlite3
mix search query 'billing address' --index var/suppliers.sqlite3
```

A search result looks like this:

```text
Travel reimbursement
/Knowledge/travel-policy.md
Employees may request [reimbursement] for [train] tickets and approved hotel stays.
id:... @ rev:...
```

All query words must match. Queries are treated as literal words, not SQL or
FTS expressions. Search is case-insensitive and uses SQLite's `unicode61`
tokenizer. Results use BM25 ranking, with matches in the title weighted more
heavily than body matches. Square brackets mark matching words in the excerpt.
This is keyword search: there are no embeddings, model calls, or generated
answers. Queries are limited to 500 characters and 20 words; the CLI returns
at most 10 matches.

## Keep the index and cursor together

```text
load cursor
    -> list changes in order
    -> download changed revisions
    -> extract text and update SQLite FTS5
    -> apply file and folder deletions
    -> follow every remaining page
    -> commit index + cursor together
```

The entire sync runs in one SQLite transaction. An API error, failed download,
or integrity mismatch rolls it back, including any earlier pages. Existing
results remain available, and the next run starts from the last committed
cursor. Replaying a change replaces the document by file ID instead of adding
another copy. Folder deletions remove their descendants using path boundaries;
deleting `/Knowledge/team` does not remove `/Knowledge/team-extra`.

A cursor is a way to maintain current state, not an audit log. The implementation
uses Magpie's existing `Files.ListFolder` endpoints. See Dropbox's
[change detection guide](https://developers.dropbox.com/detecting-changes-guide)
and [listing rules](https://www.dropbox.com/developers/documentation/http/documentation#files-list_folder).

If Dropbox rejects an expired cursor, the command asks for a rebuild:

```sh
mix search sync /Knowledge --rebuild
```

A rebuild lists the selected folder from the beginning and replaces the old
index only when the full scan succeeds. If it fails, the old index and cursor
remain intact. An empty successful scan removes all old results. Rebuild after
changing the extraction rules as well.

## Text extraction

The bundled extractor supports UTF-8 `.txt`, `.md`, and `.markdown` files up to
2 MiB. Markdown is indexed as text; its first level-one heading becomes the
title. Plain text uses the filename as its title. Formatting syntax remains in
excerpts.

Unsupported formats, oversized files, empty text, invalid UTF-8, and files that
require Dropbox export get a `skipped:...` status. They are omitted from search,
and `mix search status` shows counts by reason. If an indexed file changes into
an unsupported format, its old search text is removed. Operational download
failures stop the sync instead of being recorded as permanent skips.

[`Extractor`](lib/document_search/extractor.ex) is the place to add PDF, DOCX,
OCR, or domain-specific extraction. Extend `accept/1` and `extract/2`, return
`{:ok, %{title: title, body: text}}` for extracted text, and keep extraction
errors distinct from intentional skips. PDF, DOCX, scanned images, and Dropbox
Paper are **not supported by this sample**. A production parser should run
with its own resource limits; a large-document pipeline should pass temporary
file paths to it instead of loading the full source into memory.

The result keeps its original revision. To retrieve that exact source through
Magpie in your application:

```elixir
[hit | _] = DocumentSearch.Index.search(db, "train reimbursement")
Magpie.Storage.download(client, "rev:" <> hit.rev, "tmp/original.md", mkdir_p: true)
```

Dropbox must still retain that revision for the download to succeed. A result
path is the last indexed path, not a guarantee that the file still exists there.

## Read and adapt the code

- [`lib/document_search.ex`](lib/document_search.ex): incremental sync,
  revision downloads, integrity checks, and rebuilds.
- [`lib/document_search/index.ex`](lib/document_search/index.ex): SQLite
  transactions, document replacement, deletion, ranking, and excerpts.
- [`lib/document_search/extractor.ex`](lib/document_search/extractor.ex):
  supported formats, size limits, and title extraction.
- [`test/document_search_test.exs`](test/document_search_test.exs): restart,
  failed pages and downloads, cursor reset, scope isolation, and stale results.

Run one sync process per index. This example keeps a write transaction open
while fetching documents, which makes rollback straightforward but suits small
collections. For a large collection, stage extraction jobs outside the write
transaction and commit each batch with its checkpoint. Do not advance the
cursor before those jobs are durably recorded.

The SQLite file contains document text. Treat it and its WAL files as copies of
the source documents. This local example has no end-user authorization layer:
binding an index to an account prevents accidental mixing but is not access
control. Before serving results in a portal, authorize each reader and handle
permission changes separately. A failed sync leaves the previous snapshot
searchable, including documents whose removal has not yet been processed.
