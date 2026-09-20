defmodule DocumentSearch.SearchScenario do
  import ExUnit.Assertions
  alias DocumentSearch.{DropboxFixture, Index}

  def run(directory, output \\ fn _ -> :ok end) do
    client = DropboxFixture.client()
    path = Path.join(directory, "documents.sqlite3")
    {:ok, db} = Index.open(path)
    travel = File.read!(Path.expand("../../fixtures/travel-policy.md", __DIR__))
    on_call = File.read!(Path.expand("../../fixtures/on-call.md", __DIR__))

    first =
      DropboxFixture.metadata("/Knowledge/travel-policy.md", travel, "00000000001", "id:travel")

    second =
      DropboxFixture.metadata("/Knowledge/on-call.md", on_call, "00000000002", "id:on-call")

    try do
      DropboxFixture.account()

      DropboxFixture.rpc(
        "list_folder",
        %{"path" => "/knowledge", "recursive" => true, "include_deleted" => true},
        DropboxFixture.page([first], "page-1", true)
      )

      DropboxFixture.download("rev:00000000001", travel)

      DropboxFixture.rpc(
        "list_folder/continue",
        %{"cursor" => "page-1"},
        DropboxFixture.page([second], "ready")
      )

      DropboxFixture.download("rev:00000000002", on_call)
      assert {:ok, %{cursor: "ready"}} = DocumentSearch.sync(client, db, "/Knowledge")
      assert [hit] = Index.search(db, "train reimbursement")
      assert hit.rev == "00000000001"
      output.("Indexed 2 documents across 2 pages.")
      output.("Search: train reimbursement\n#{hit.path}\n#{hit.excerpt}\nRevision: #{hit.rev}")
    after
      Index.close(db)
    end

    {:ok, reopened} = Index.open(path)

    try do
      updated = String.replace(travel, "thirty", "fourteen")

      moved =
        DropboxFixture.metadata(
          "/Knowledge/policies/travel.md",
          updated,
          "00000000003",
          "id:travel"
        )

      DropboxFixture.account()

      DropboxFixture.rpc(
        "list_folder/continue",
        %{"cursor" => "ready"},
        DropboxFixture.page(
          [
            DropboxFixture.deleted(first["path_display"]),
            moved,
            DropboxFixture.deleted(second["path_display"])
          ],
          "updated"
        )
      )

      DropboxFixture.download("rev:00000000003", updated)
      assert {:ok, %{cursor: "updated"}} = DocumentSearch.sync(client, reopened, "/Knowledge")
      assert [hit] = Index.search(reopened, "fourteen")
      assert hit.path == "/Knowledge/policies/travel.md"
      assert hit.rev == "00000000003"
      assert Index.search(reopened, "thirty") == []
      assert Index.search(reopened, "incident") == []

      output.(
        "Reopened the index and resumed its cursor. Updated the moved policy and removed the deleted handbook."
      )

      output.("Search: fourteen\n#{hit.path}\n#{hit.excerpt}\nRevision: #{hit.rev}")
      DropboxFixture.verify!()
    after
      Index.close(reopened)
    end
  end
end
