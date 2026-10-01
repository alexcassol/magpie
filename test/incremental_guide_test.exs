defmodule Magpie.IncrementalGuideTest do
  use ExUnit.Case, async: true
  alias MagpieGuide.Scanner
  alias Magpie.Client
  @client Client.new("fake")

  defp stub_pages do
    Req.Test.stub(Magpie, fn conn ->
      case Jason.decode!(Req.Test.raw_body(conn)) do
        %{"path" => "", "recursive" => true, "include_deleted" => true, "limit" => 100} ->
          Req.Test.json(conn, %{
            "entries" => [%{".tag" => "file", "name" => "a", "rev" => "1"}],
            "cursor" => "first",
            "has_more" => true
          })

        %{"cursor" => "first"} ->
          Req.Test.json(conn, %{"entries" => [], "cursor" => "final", "has_more" => false})

        %{"cursor" => "expired"} ->
          conn |> Plug.Conn.put_status(409) |> Req.Test.json(%{"error" => %{".tag" => "reset"}})
      end
    end)
  end

  test "documented scanner saves only successfully processed pages, including empty final pages" do
    stub_pages()
    {:ok, storage} = Agent.start_link(fn -> %{cursor: nil, names: []} end)

    commit = fn page ->
      Agent.update(storage, fn state ->
        %{cursor: page.cursor, names: Enum.uniq(state.names ++ Enum.map(page.entries, & &1.name))}
      end)
    end

    assert {:ok, "final"} = Scanner.scan(@client, "", nil, commit)
    assert %{cursor: "final", names: ["a"]} = Agent.get(storage, & &1)
    # An external checkpoint can resume after a worker restart.
    Agent.update(storage, &%{&1 | cursor: "first"})

    assert {:ok, "final"} =
             Scanner.scan(Client.new("new"), "", Agent.get(storage, & &1.cursor), commit)

    assert %{cursor: "final", names: ["a"]} = Agent.get(storage, & &1)
    Agent.stop(storage)
  end

  test "commit failure does not fetch the next page or save the cursor" do
    pid = self()

    Req.Test.stub(Magpie, fn conn ->
      assert conn.request_path == "/2/files/list_folder"
      send(pid, :fetched)
      Req.Test.json(conn, %{"entries" => [], "cursor" => "unsaved", "has_more" => true})
    end)

    assert {:error, :commit_failed} =
             Scanner.scan(@client, "", nil, fn _ -> {:error, :commit_failed} end)

    assert_received :fetched
    refute_received :fetched
  end

  test "documented reset recovery publishes a fresh shadow and removes stale entries" do
    stub_pages()
    Process.put(:guide_live, {[:stale], "expired"})
    assert {:ok, "final"} = MagpieGuide.TestRecovery.run_locked(@client, "account", "", "expired")
    assert {[%Magpie.FileMetadata{name: "a"}], "final"} = Process.get(:guide_live)
    assert Process.get(:guide_shadow) == nil
  end

  test "failed rebuild retains live state and cleans staging" do
    Req.Test.stub(Magpie, fn conn ->
      case conn.request_path do
        "/2/files/list_folder/continue" ->
          conn |> Plug.Conn.put_status(409) |> Req.Test.json(%{"error" => %{".tag" => "reset"}})

        "/2/files/list_folder" ->
          conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error_summary" => "unavailable"})
      end
    end)

    Process.put(:guide_live, {[:stale], "expired"})

    assert {:error, %Magpie.Error{status: 503}} =
             MagpieGuide.TestRecovery.run_locked(@client, "account", "", "expired")

    assert Process.get(:guide_live) == {[:stale], "expired"}
    assert Process.get(:guide_shadow) == nil
  end

  test "documented endpoint enqueues accounts and the leased scan recovers from reset" do
    stub_pages()
    Process.put(:guide_live, {[:stale], "expired"})
    body = "{\n \"list_folder\": {\"accounts\": [\"account\"]}\n}"

    signature =
      :crypto.mac(:hmac, :sha256, "fake-app-secret", body) |> Base.encode16(case: :lower)

    conn =
      Plug.Test.conn(:post, "/webhooks/dropbox", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-dropbox-signature", signature)
      |> MagpieGuide.TestEndpoint.call(MagpieGuide.TestEndpoint.init([]))

    assert conn.status == 200 and conn.halted
    assert conn.private.magpie_webhook_raw_body == body
    assert match?(%Plug.Conn.Unfetched{}, conn.body_params)
    assert_received {:enqueue, [account]}
    assert {:ok, "final"} = MagpieGuide.TestScan.run(account)
    assert_received :lease_acquired
    assert_received :lease_released
    assert Process.get(:guide_lease) == nil
    assert {[%Magpie.FileMetadata{name: "a"}], "final"} = Process.get(:guide_live)
  end

  test "documented scanner releases its account lease on failure" do
    Req.Test.stub(Magpie, &Req.Test.transport_error(&1, :timeout))
    assert {:error, %Req.TransportError{}} = MagpieGuide.TestScan.run("account")
    assert_received :lease_acquired
    assert_received :lease_released
    assert Process.get(:guide_lease) == nil
  end

  test "incremental README snippet runs unchanged against offline pages" do
    Req.Test.stub(Magpie, fn conn ->
      case Jason.decode!(Req.Test.raw_body(conn)) do
        %{"path" => "", "recursive" => true, "include_deleted" => true} ->
          Req.Test.json(conn, %{"entries" => [], "cursor" => "first", "has_more" => true})

        %{"cursor" => "first"} ->
          Req.Test.json(conn, %{"entries" => [], "cursor" => "final", "has_more" => false})
      end
    end)

    {_, bindings} = Code.eval_string(MagpieGuide.Examples.block("incremental"), client: @client)
    assert bindings[:page].cursor == "first"
    assert bindings[:next].cursor == "final"
    refute bindings[:next].has_more
  end

  test "documented recursive latest cursor skips the initial listing and reads later changes" do
    Req.Test.stub(Magpie, fn conn ->
      case conn.request_path do
        "/2/files/list_folder/get_latest_cursor" ->
          assert Jason.decode!(Req.Test.raw_body(conn)) == %{
                   "path" => "",
                   "recursive" => true,
                   "include_deleted" => true
                 }

          Req.Test.json(conn, %{"cursor" => "starting-point"})

        "/2/files/list_folder/continue" ->
          assert Jason.decode!(Req.Test.raw_body(conn)) == %{"cursor" => "starting-point"}

          Req.Test.json(conn, %{
            "entries" => [%{".tag" => "deleted", "name" => "removed"}],
            "cursor" => "updated",
            "has_more" => false
          })
      end
    end)

    {_, bindings} = Code.eval_string(MagpieGuide.Examples.block("latest-cursor"), client: @client)
    assert bindings[:cursor] == "starting-point"
    assert bindings[:page].cursor == "updated"
    assert [%Magpie.DeletedMetadata{name: "removed"}] = bindings[:page].entries
  end
end
