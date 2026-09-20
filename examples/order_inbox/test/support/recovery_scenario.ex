defmodule OrderInbox.RecoveryScenario do
  import ExUnit.Assertions
  alias OrderInbox.{DropboxFixture, Journal}

  def run(directory, output \\ fn _ -> :ok end) do
    client = DropboxFixture.client()
    body = File.read!(Path.expand("../../fixtures/orders.csv", __DIR__))
    source = DropboxFixture.metadata("/MagpieOrders/Incoming/orders.csv", body)
    file = Magpie.Metadata.decode(source)
    key = OrderInbox.key(file)
    processing = "/MagpieOrders/Processing/" <> key <> ".csv"
    archived = "/MagpieOrders/Processed/" <> key <> ".csv"
    claimed = DropboxFixture.metadata(processing, body)
    journal_path = Path.join(directory, "orders.json")
    {:ok, journal} = Journal.start_link(journal_path)

    DropboxFixture.rpc("move_v2", %{"from_path" => file.id, "to_path" => processing}, %{
      "metadata" => claimed
    })

    DropboxFixture.download("rev:" <> file.rev, body)
    expect_report(key)
    DropboxFixture.rpc("get_metadata", %{"path" => file.id}, claimed)

    Req.Test.expect(DropboxFixture, fn conn ->
      assert conn.request_path == "/2/files/move_v2"
      assert Jason.decode!(Req.Test.raw_body(conn))["to_path"] == archived
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:error, %Req.TransportError{reason: :timeout}} =
             OrderInbox.process(client, journal, "/MagpieOrders", file)

    assert map_size(Journal.snapshot(journal)["orders"]) == 2
    output.("Imported 2 orders. Archive failed; the receipt is still pending.")
    GenServer.stop(journal)

    {:ok, recovered} = Journal.start_link(journal_path)

    try do
      expect_report(key)
      # The move may have succeeded remotely even though the caller saw an error.
      DropboxFixture.rpc(
        "get_metadata",
        %{"path" => file.id},
        DropboxFixture.metadata(archived, body)
      )

      for folder <- ["Processing", "Incoming"] do
        DropboxFixture.rpc("list_folder", %{"path" => "/MagpieOrders/" <> folder}, %{
          "entries" => [],
          "cursor" => "done",
          "has_more" => false
        })
      end

      assert {:ok, [{^key, {:ok, %{"delivered" => true}}}]} =
               OrderInbox.run(client, recovered, "/MagpieOrders")

      assert map_size(Journal.snapshot(recovered)["orders"]) == 2
      DropboxFixture.verify!()
      output.("Restarted from disk. Archive confirmed; still 2 orders, no second CSV download.")
    after
      GenServer.stop(recovered)
    end
  end

  defp expect_report(key) do
    DropboxFixture.upload(fn args, body ->
      assert args["path"] == "/MagpieOrders/Reports/" <> key <> ".json"
      assert args["mode"] == "overwrite"
      assert args["autorename"] == false
      assert %{"outcome" => "imported", "count" => 2} = Jason.decode!(body)
    end)
  end
end
