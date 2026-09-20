defmodule DocumentSearchTest do
  use ExUnit.Case, async: true
  alias DocumentSearch.{DropboxFixture, Extractor, Index}
  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    Req.Test.verify_on_exit!()
    {:ok, db} = Index.open(Path.join(directory, "test.sqlite3"))
    on_exit(fn -> Index.close(db) end)
    %{db: db, client: DropboxFixture.client()}
  end

  test "offline demo indexes pages, survives restart, and applies updates and deletions", %{
    tmp_dir: directory
  } do
    DocumentSearch.SearchScenario.run(directory)
  end

  test "unchanged revision updates its path without downloading again", %{db: db, client: client} do
    seed(db)
    moved = metadata("/Knowledge/moved.md", "00000000001")
    DropboxFixture.account()

    DropboxFixture.rpc(
      "list_folder/continue",
      %{"cursor" => "old"},
      DropboxFixture.page([moved, DropboxFixture.deleted("/Knowledge/guide.md")], "new")
    )

    assert {:ok, _} = DocumentSearch.sync(client, db, "/Knowledge")
    assert [%{path: "/Knowledge/moved.md"}] = Index.search(db, "old policy")
  end

  test "later page failure rolls back text updates, deletions, and the cursor", %{
    db: db,
    client: client
  } do
    seed(db)
    body = "# New policy\nUpdated reimbursement rules."
    entry = DropboxFixture.metadata("/Knowledge/new.md", body, "00000000002", "id:new")
    DropboxFixture.account()

    DropboxFixture.rpc(
      "list_folder/continue",
      %{"cursor" => "old"},
      DropboxFixture.page([DropboxFixture.deleted("/Knowledge/guide.md"), entry], "partial", true)
    )

    DropboxFixture.download("rev:00000000002", body)

    DropboxFixture.rpc(
      "list_folder/continue",
      %{"cursor" => "partial"},
      %{"error_summary" => "unavailable"},
      503
    )

    assert {:error, %Magpie.Error{status: 503}} = DocumentSearch.sync(client, db, "/Knowledge")
    assert Index.cursor(db) == "old"
    assert [_] = Index.search(db, "old policy")
    assert [] == Index.search(db, "updated")
  end

  test "failed download can retry the same cursor without duplicate documents", %{
    db: db,
    client: client
  } do
    seed(db)
    body = "# New policy\nUpdated reimbursement rules."
    changed = DropboxFixture.metadata("/Knowledge/guide.md", body, "00000000002", "id:guide")

    for fail <- [true, false] do
      DropboxFixture.account()

      DropboxFixture.rpc(
        "list_folder/continue",
        %{"cursor" => "old"},
        DropboxFixture.page([changed], "new")
      )

      if fail do
        Req.Test.expect(DropboxFixture, fn conn -> Req.Test.transport_error(conn, :timeout) end)

        assert {:error, {:document_failed, "id:guide", _}} =
                 DocumentSearch.sync(client, db, "/Knowledge")

        assert Index.cursor(db) == "old"
      else
        DropboxFixture.download("rev:00000000002", body)
        assert {:ok, _} = DocumentSearch.sync(client, db, "/Knowledge")
      end
    end

    assert [] == Index.search(db, "old")
    assert [%{rev: "00000000002"}] = Index.search(db, "updated")
  end

  test "corrupt bytes never replace the indexed revision", %{db: db, client: client} do
    seed(db)
    DropboxFixture.account()

    DropboxFixture.rpc(
      "list_folder/continue",
      %{},
      DropboxFixture.page([metadata("/Knowledge/guide.md", "00000000002")], "new")
    )

    DropboxFixture.download("rev:00000000002", "wrong content")

    assert {:error, {:document_failed, _, :integrity_mismatch}} =
             DocumentSearch.sync(client, db, "/Knowledge")

    assert [%{rev: "00000000001"}] = Index.search(db, "old")
  end

  test "folder deletion removes descendants without deleting a similarly named folder", %{
    db: db,
    client: client
  } do
    seed(db)

    for path <- [
          "/Knowledge/team/a.md",
          "/Knowledge/team/nested/b.md",
          "/Knowledge/team-extra/c.md"
        ] do
      file = metadata(path, "00000000001", "id:" <> path) |> Magpie.Metadata.decode()
      Index.put(db, file, "file", "Guide", "old policy", "indexed")
    end

    DropboxFixture.account()

    DropboxFixture.rpc(
      "list_folder/continue",
      %{},
      DropboxFixture.page([DropboxFixture.deleted("/Knowledge/team")], "new")
    )

    assert {:ok, _} = DocumentSearch.sync(client, db, "/Knowledge")

    assert Enum.map(Index.search(db, "old"), & &1.path) == [
             "/Knowledge/guide.md",
             "/Knowledge/team-extra/c.md"
           ]
  end

  test "unsupported replacement removes obsolete search text and records its reason", %{
    db: db,
    client: client
  } do
    seed(db)
    renamed = metadata("/Knowledge/guide.pdf", "00000000001")
    DropboxFixture.account()
    DropboxFixture.rpc("list_folder/continue", %{}, DropboxFixture.page([renamed], "new"))
    assert {:ok, _} = DocumentSearch.sync(client, db, "/Knowledge")
    assert Index.search(db, "old") == []
    assert Index.status(db).counts == [["skipped:unsupported_format", 1]]
  end

  test "account and folder bindings prevent accidental index reuse", %{db: db, client: client} do
    seed(db)

    for {account, root} <- [{"dbid:another", "/Knowledge"}, {"dbid:demo", "/Other"}] do
      DropboxFixture.account(account)

      assert {:error, :index_scope_mismatch} =
               DocumentSearch.sync(client, db, root, rebuild: true)
    end

    assert Index.cursor(db) == "old"
  end

  test "cursor reset preserves results; rebuilding removes stale documents only on success", %{
    db: db,
    client: client
  } do
    seed(db)
    DropboxFixture.account()

    DropboxFixture.rpc(
      "list_folder/continue",
      %{},
      %{"error_summary" => "reset/", "error" => %{".tag" => "reset"}},
      409
    )

    assert {:error, :cursor_reset_rebuild_required} =
             DocumentSearch.sync(client, db, "/Knowledge")

    DropboxFixture.account()
    DropboxFixture.rpc("list_folder", %{}, %{"error_summary" => "unavailable"}, 503)
    assert {:error, _} = DocumentSearch.sync(client, db, "/Knowledge", rebuild: true)
    assert [_] = Index.search(db, "old")
    DropboxFixture.account()
    DropboxFixture.rpc("list_folder", %{}, DropboxFixture.page([], "rebuilt"))

    assert {:ok, %{cursor: "rebuilt"}} =
             DocumentSearch.sync(client, db, "/Knowledge", rebuild: true)

    assert Index.search(db, "old") == []
  end

  test "empty change pages still advance the checkpoint", %{db: db, client: client} do
    seed(db)
    DropboxFixture.account()

    DropboxFixture.rpc(
      "list_folder/continue",
      %{"cursor" => "old"},
      DropboxFixture.page([], "fresh")
    )

    assert {:ok, %{cursor: "fresh"}} = DocumentSearch.sync(client, db, "/Knowledge")
    assert [_] = Index.search(db, "old")
  end

  test "folder metadata preserves children but replacing it with a file removes them", %{
    db: db,
    client: client
  } do
    seed(db)

    child =
      metadata("/Knowledge/team/guide.md", "00000000001", "id:child") |> Magpie.Metadata.decode()

    Index.put(db, child, "file", "Old policy", "old policy", "indexed")
    DropboxFixture.account()

    DropboxFixture.rpc(
      "list_folder/continue",
      %{},
      DropboxFixture.page([DropboxFixture.folder("/Knowledge/team")], "folder")
    )

    assert {:ok, _} = DocumentSearch.sync(client, db, "/Knowledge")
    assert length(Index.search(db, "old")) == 2
    DropboxFixture.account()
    replacement = metadata("/Knowledge/team", "00000000003", "id:replacement")

    DropboxFixture.rpc(
      "list_folder/continue",
      %{"cursor" => "folder"},
      DropboxFixture.page([replacement], "file")
    )

    assert {:ok, _} = DocumentSearch.sync(client, db, "/Knowledge")
    assert [%{path: "/Knowledge/guide.md"}] = Index.search(db, "old")
  end

  test "a database write failure rolls back search data and leaves the connection usable", %{
    db: db
  } do
    seed(db)

    assert_raise MatchError, fn ->
      Index.transaction(db, fn ->
        Index.clear(db)
        Index.query!(db, "INSERT INTO state VALUES (2, 'account', 'root', NULL)")
        {:ok, :unreachable}
      end)
    end

    assert Index.cursor(db) == "old"
    assert [_] = Index.search(db, "old")
    assert {:ok, :still_usable} = Index.transaction(db, fn -> {:ok, :still_usable} end)
  end

  test "search uses literal terms, all terms are required, and matching excerpts carry the revision",
       %{db: db} do
    seed(db)
    assert [%{excerpt: excerpt, rev: "00000000001"}] = Index.search(db, "old policy")
    assert excerpt =~ "[Old]"
    assert [] == Index.search(db, "old missing")
    assert [] == Index.search(db, "\" OR * NEAR()")
    assert [] == Index.search(db, "")
    assert [_] = Index.search(db, "policy'; --")
  end

  test "extractor records empty, binary, oversized and export-only documents" do
    assert {:skip, "empty_text"} = Extractor.extract(" \n", "a.txt")
    assert {:skip, "not_utf8_text"} = Extractor.extract(<<255>>, "a.txt")
    assert {:skip, "not_utf8_text"} = Extractor.extract(<<0>>, "a.txt")
    file = metadata("/Knowledge/a.txt") |> Magpie.Metadata.decode()
    assert {:skip, "too_large"} = Extractor.accept(%{file | size: 3 * 1024 * 1024})
    assert {:skip, "requires_export"} = Extractor.accept(%{file | is_downloadable: false})
  end

  defp seed(db) do
    {:ok, :seeded} =
      Index.transaction(db, fn ->
        :ok = Index.bind(db, "dbid:demo", "/knowledge")
        file = metadata("/Knowledge/guide.md") |> Magpie.Metadata.decode()

        Index.put(
          db,
          file,
          "file",
          "Old policy",
          "# Old policy\nKeep receipts for reimbursement.",
          "indexed"
        )

        Index.checkpoint(db, "old")
        {:ok, :seeded}
      end)
  end

  defp metadata(path, rev \\ "00000000001", id \\ "id:guide"),
    do: DropboxFixture.metadata(path, "# Old policy\nKeep receipts for reimbursement.", rev, id)
end
