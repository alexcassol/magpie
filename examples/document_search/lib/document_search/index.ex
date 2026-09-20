defmodule DocumentSearch.Index do
  @moduledoc "SQLite stores document text, search terms, and the Dropbox cursor in one transaction."
  alias Exqlite.Sqlite3

  def open(path) do
    File.mkdir_p!(Path.dirname(Path.expand(path)))
    {:ok, db} = Sqlite3.open(path)

    try do
      execute!(db, """
      PRAGMA journal_mode = WAL;
      PRAGMA synchronous = FULL;
      CREATE TABLE IF NOT EXISTS state (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        account TEXT NOT NULL, root TEXT NOT NULL, cursor TEXT
      );
      CREATE TABLE IF NOT EXISTS nodes (
        id TEXT PRIMARY KEY, path TEXT UNIQUE NOT NULL, display_path TEXT NOT NULL,
        kind TEXT NOT NULL, rev TEXT, title TEXT NOT NULL, body TEXT NOT NULL,
        status TEXT NOT NULL
      );
      CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(
        id UNINDEXED, title, body, tokenize = 'unicode61'
      );
      """)

      {:ok, db}
    rescue
      exception ->
        Sqlite3.close(db)
        reraise exception, __STACKTRACE__
    end
  end

  def close(db), do: Sqlite3.close(db)

  def transaction(db, fun) do
    case Sqlite3.execute(db, "BEGIN IMMEDIATE") do
      :ok ->
        try do
          case fun.() do
            {:ok, _} = result ->
              execute!(db, "COMMIT")
              result

            {:error, _} = error ->
              execute!(db, "ROLLBACK")
              error
          end
        after
          # Also release the transaction if extraction raises or exits.
          Sqlite3.execute(db, "ROLLBACK")
        end

      {:error, reason} ->
        {:error, {:index_busy_or_unavailable, reason}}
    end
  end

  def bind(db, account, root) do
    case query!(db, "SELECT account, root FROM state") do
      [] ->
        query!(db, "INSERT INTO state VALUES (1, ?, ?, NULL)", [account, root])
        :ok

      [[^account, ^root]] ->
        :ok

      _ ->
        {:error, :index_scope_mismatch}
    end
  end

  def cursor(db) do
    case query!(db, "SELECT cursor FROM state") do
      [[cursor]] -> cursor
      [] -> nil
    end
  end

  def checkpoint(db, cursor), do: query!(db, "UPDATE state SET cursor = ?", [cursor])

  def clear(db) do
    execute!(db, "DELETE FROM search; DELETE FROM nodes; UPDATE state SET cursor = NULL;")
  end

  def node(db, id) do
    case query!(db, "SELECT path, rev, title, body, status FROM nodes WHERE id = ?", [id]) do
      [[path, rev, title, body, status]] ->
        %{path: path, rev: rev, title: title, body: body, status: status}

      [] ->
        nil
    end
  end

  def remove_path(db, path) do
    ids =
      query!(
        db,
        "SELECT id FROM nodes WHERE path = ? OR substr(path, 1, length(?) + 1) = ? || '/'",
        [path, path, path]
      )

    Enum.each(ids, fn [id] -> remove_id(db, id) end)
  end

  def remove_id(db, id) do
    query!(db, "DELETE FROM search WHERE id = ?", [id])
    query!(db, "DELETE FROM nodes WHERE id = ?", [id])
  end

  def put(db, file, kind, title, body, status) do
    remove_id(db, file.id)

    query!(db, "INSERT INTO nodes VALUES (?, ?, ?, ?, ?, ?, ?, ?)", [
      file.id,
      file.path_lower,
      file.path_display,
      kind,
      Map.get(file, :rev),
      title,
      body,
      status
    ])

    if status == "indexed" do
      query!(db, "INSERT INTO search (id, title, body) VALUES (?, ?, ?)", [file.id, title, body])
    end

    :ok
  end

  # Folder entries replace metadata at that path without removing its children.
  def put_folder(db, folder) do
    case query!(db, "SELECT id, kind FROM nodes WHERE path = ?", [folder.path_lower]) do
      [[id, _]] -> remove_id(db, id)
      [] -> :ok
    end

    put(db, folder, "folder", folder.name, "", "folder")
  end

  def search(db, text, limit \\ 10) when is_integer(limit) and limit in 1..100 do
    terms =
      Regex.scan(~r/[\p{L}\p{N}]+/u, String.slice(text, 0, 500))
      |> List.flatten()
      |> Enum.take(20)

    case terms do
      [] ->
        []

      _ ->
        match = Enum.map_join(terms, " AND ", &("\"" <> &1 <> "\""))

        query!(
          db,
          """
          SELECT nodes.id, nodes.display_path, nodes.rev, search.title,
                 snippet(search, 2, '[', ']', ' ... ', 24), bm25(search, 0.0, 5.0, 1.0)
          FROM search JOIN nodes ON nodes.id = search.id
          WHERE search MATCH ?
          ORDER BY bm25(search, 0.0, 5.0, 1.0), nodes.path LIMIT ?
          """,
          [match, limit]
        )
        |> Enum.map(fn [id, path, rev, title, excerpt, score] ->
          %{id: id, path: path, rev: rev, title: title, excerpt: excerpt, score: score}
        end)
    end
  end

  def status(db) do
    %{
      cursor: cursor(db),
      counts: query!(db, "SELECT status, count(*) FROM nodes GROUP BY status ORDER BY status")
    }
  end

  def query!(db, sql, parameters \\ []) do
    {:ok, statement} = Sqlite3.prepare(db, sql)

    try do
      :ok = Sqlite3.bind(statement, parameters)
      {:ok, rows} = Sqlite3.fetch_all(db, statement)
      rows
    after
      Sqlite3.release(db, statement)
    end
  end

  defp execute!(db, sql), do: :ok = Sqlite3.execute(db, sql)
end
