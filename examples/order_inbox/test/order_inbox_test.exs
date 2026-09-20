defmodule OrderInboxTest do
  use ExUnit.Case, async: true
  alias OrderInbox.{CSV, DropboxFixture, Journal}
  @moduletag :tmp_dir

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "restart finishes an ambiguous archive without importing again", %{tmp_dir: dir} do
    OrderInbox.RecoveryScenario.run(dir)
  end

  test "setup creates the inbox folders on a new account" do
    for path <- [
          "/MagpieOrders"
          | Enum.map(
              ["Incoming", "Processing", "Processed", "Rejected", "Reports"],
              &("/MagpieOrders/" <> &1)
            )
        ] do
      DropboxFixture.rpc(
        "get_metadata",
        %{"path" => path},
        %{
          "error_summary" => "path/not_found/",
          "error" => %{".tag" => "path", "path" => %{".tag" => "not_found"}}
        },
        409
      )

      DropboxFixture.rpc("create_folder_v2", %{"path" => path}, %{
        "metadata" => DropboxFixture.folder(path)
      })
    end

    assert :ok = OrderInbox.setup(DropboxFixture.client(), "/MagpieOrders")
  end

  test "pending receipt retries a move that did not happen", %{tmp_dir: dir} do
    journal = start_supervised!({Journal, Path.join(dir, "journal.json")})
    body = "order_id,sku,quantity\nA,MUG,1\n"
    metadata = DropboxFixture.metadata("/MagpieOrders/Processing/orders.csv", body)
    file = Magpie.Metadata.decode(metadata)
    key = OrderInbox.key(file)

    {:ok, _} =
      Journal.record(
        journal,
        %{
          "key" => key,
          "file_id" => file.id,
          "rev" => file.rev,
          "source" => file.path_display,
          "delivered" => false
        },
        CSV.parse(body)
      )

    DropboxFixture.upload(fn _, _ -> :ok end)
    DropboxFixture.rpc("get_metadata", %{"path" => file.id}, metadata)

    DropboxFixture.rpc(
      "move_v2",
      %{"from_path" => file.id, "to_path" => "/MagpieOrders/Processed/" <> key <> ".csv"},
      %{"metadata" => metadata}
    )

    for folder <- ["Processing", "Incoming"] do
      DropboxFixture.rpc("list_folder", %{"path" => "/MagpieOrders/" <> folder}, %{
        "entries" => [],
        "cursor" => "done",
        "has_more" => false
      })
    end

    assert {:ok, [{^key, {:ok, %{"delivered" => true}}}]} =
             OrderInbox.run(DropboxFixture.client(), journal, "/MagpieOrders")

    assert map_size(Journal.snapshot(journal)["orders"]) == 1
  end

  test "CSV supports quoted fields and rejects the whole file on bad rows" do
    assert {:ok, [%{"sku" => "MUG, BLUE", "quantity" => 3}]} =
             CSV.parse("order_id,sku,quantity\nA,\"MUG, BLUE\",3\n")

    for body <- [
          "order_id,sku,quantity\nA,MUG,1\nA,BOOK,2\n",
          "order_id,sku,quantity\nA,MUG,1\nB,BOOK,-1\n",
          "sku,quantity\nMUG,3\n",
          "order_id,sku,quantity\n"
        ] do
      assert {:error, [_ | _]} = CSV.parse(body)
    end
  end

  test "duplicate business IDs from another receipt reject all its rows", %{tmp_dir: dir} do
    journal = start_supervised!({Journal, Path.join(dir, "journal.json")})
    {:ok, rows} = CSV.parse("order_id,sku,quantity\nA,MUG,1\n")
    receipt = %{"key" => "first", "delivered" => false}
    assert {:ok, %{"outcome" => "imported"}} = Journal.record(journal, receipt, {:ok, rows})
    assert {:ok, %{"outcome" => "imported"}} = Journal.record(journal, receipt, {:ok, rows})
    {:ok, conflicting} = CSV.parse("order_id,sku,quantity\nB,BOOK,2\nA,MUG,1\n")

    assert {:ok, %{"outcome" => "rejected"}} =
             Journal.record(journal, %{receipt | "key" => "second"}, {:ok, conflicting})

    assert Map.keys(Journal.snapshot(journal)["orders"]) == ["A"]
  end

  test "rejected CSV is reported and archived without storing orders", %{tmp_dir: dir} do
    journal = start_supervised!({Journal, Path.join(dir, "journal.json")})
    body = File.read!(Path.expand("../fixtures/invalid.csv", __DIR__))
    metadata = DropboxFixture.metadata("/MagpieOrders/Processing/invalid.csv", body)
    file = Magpie.Metadata.decode(metadata)
    key = OrderInbox.key(file)
    DropboxFixture.download("rev:" <> file.rev, body)

    DropboxFixture.upload(fn _args, report ->
      assert %{"outcome" => "rejected", "count" => 0} = Jason.decode!(report)
    end)

    DropboxFixture.rpc("get_metadata", %{"path" => file.id}, metadata)

    DropboxFixture.rpc("move_v2", %{"to_path" => "/MagpieOrders/Rejected/" <> key <> ".csv"}, %{
      "metadata" => metadata
    })

    assert {:ok, %{"outcome" => "rejected", "delivered" => true}} =
             OrderInbox.process(DropboxFixture.client(), journal, "/MagpieOrders", file)

    assert Journal.snapshot(journal)["orders"] == %{}
  end

  test "edited source remains pending instead of archiving another revision", %{tmp_dir: dir} do
    journal = start_supervised!({Journal, Path.join(dir, "journal.json")})
    body = "order_id,sku,quantity\nA,MUG,1\n"
    metadata = DropboxFixture.metadata("/MagpieOrders/Processing/orders.csv", body)
    file = Magpie.Metadata.decode(metadata)
    DropboxFixture.download("rev:" <> file.rev, body)
    DropboxFixture.upload(fn _, _ -> :ok end)
    DropboxFixture.rpc("get_metadata", %{"path" => file.id}, %{metadata | "rev" => "00000000009"})

    assert {:error, :revision_changed} =
             OrderInbox.process(DropboxFixture.client(), journal, "/MagpieOrders", file)

    assert Journal.snapshot(journal)["receipts"][OrderInbox.key(file)]["delivered"] == false
  end

  test "a journal write failure does not commit orders in memory", %{tmp_dir: dir} do
    journal = start_supervised!({Journal, Path.join(dir, "journal.json")})
    File.mkdir!(Path.join(dir, "journal.json.pending"))
    {:ok, rows} = CSV.parse("order_id,sku,quantity\nA,MUG,1\n")

    assert {:error, {:journal_write, _}} =
             Journal.record(journal, %{"key" => "first"}, {:ok, rows})

    assert Journal.snapshot(journal)["orders"] == %{}
  end
end
