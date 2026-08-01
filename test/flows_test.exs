defmodule MagpieFlowsTest do
  @moduledoc """
  Tests for the high-level flows: smart upload, lazy pagination and
  async job awaiting.
  """
  use ExUnit.Case, async: true

  alias Magpie.Client

  @client Client.new("fake-token")

  describe "Files.upload_file/4 (smart upload)" do
    @tag :tmp_dir
    test "small files go through a single /files/upload call", %{tmp_dir: dir} do
      local = Path.join(dir, "small.txt")
      File.write!(local, "tiny")

      Req.Test.stub(Magpie, fn conn ->
        assert conn.request_path == "/2/files/upload"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == "tiny"
        Req.Test.json(conn, %{"name" => "small.txt"})
      end)

      assert {:ok, %{"name" => "small.txt"}} =
               Magpie.Files.upload_file(@client, "/small.txt", local)
    end

    @tag :tmp_dir
    test "large files stream through an upload session in chunks", %{tmp_dir: dir} do
      local = Path.join(dir, "big.bin")
      File.write!(local, "0123456789AB")
      test_pid = self()

      Req.Test.stub(Magpie, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        arg = conn |> Plug.Conn.get_req_header("dropbox-api-arg") |> decode_arg()
        send(test_pid, {:call, conn.request_path, arg, body})
        respond_session(conn, conn.request_path)
      end)

      assert {:ok, %{"name" => "big.bin"}} =
               Magpie.Files.upload_file(@client, "/big.bin", local,
                 session_threshold: 1,
                 chunk_size: 5
               )

      assert_received {:call, "/2/files/upload_session/start", _, ""}

      assert_received {:call, "/2/files/upload_session/append_v2",
                       %{"cursor" => %{"offset" => 0}}, "01234"}

      assert_received {:call, "/2/files/upload_session/append_v2",
                       %{"cursor" => %{"offset" => 5}}, "56789"}

      assert_received {:call, "/2/files/upload_session/append_v2",
                       %{"cursor" => %{"offset" => 10}}, "AB"}

      assert_received {:call, "/2/files/upload_session/finish",
                       %{"cursor" => %{"offset" => 12}, "commit" => %{"path" => "/big.bin"}}, ""}
    end

    @tag :tmp_dir
    test "a failed append halts the session and returns the error", %{tmp_dir: dir} do
      local = Path.join(dir, "big.bin")
      File.write!(local, "0123456789")

      Req.Test.stub(Magpie, fn conn ->
        respond_failing_append(conn, conn.request_path)
      end)

      assert {:error, %Magpie.Error{status: 409}} =
               Magpie.Files.upload_file(@client, "/big.bin", local,
                 session_threshold: 1,
                 chunk_size: 5
               )
    end

    test "unreadable local file returns a posix error without any request" do
      assert {:error, :enoent} = Magpie.Files.upload_file(@client, "/x", "no/such/file")
    end

    defp decode_arg([arg]), do: Jason.decode!(arg)
    defp decode_arg([]), do: %{}

    defp respond_session(conn, "/2/files/upload_session/start"),
      do: Req.Test.json(conn, %{"session_id" => "sess-1"})

    defp respond_session(conn, "/2/files/upload_session/append_v2"),
      do: Req.Test.json(conn, nil)

    defp respond_session(conn, "/2/files/upload_session/finish"),
      do: Req.Test.json(conn, %{"name" => "big.bin"})

    defp respond_failing_append(conn, "/2/files/upload_session/start"),
      do: Req.Test.json(conn, %{"session_id" => "sess-1"})

    defp respond_failing_append(conn, "/2/files/upload_session/append_v2") do
      conn
      |> Plug.Conn.put_status(409)
      |> Req.Test.json(%{"error_summary" => "incorrect_offset/"})
    end
  end

  describe "Pager (lazy pagination)" do
    test "streams across pages via the continue endpoint" do
      test_pid = self()

      Req.Test.stub(Magpie, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:page_request, conn.request_path})
        respond_page(conn, conn.request_path, Jason.decode!(body))
      end)

      names =
        @client
        |> Magpie.Files.ListFolder.stream("/Photos")
        |> Enum.map(& &1["name"])

      assert names == ["a.jpg", "b.jpg", "c.jpg"]
      assert_received {:page_request, "/2/files/list_folder"}
      assert_received {:page_request, "/2/files/list_folder/continue"}
    end

    test "is lazy: does not fetch the next page unless needed" do
      test_pid = self()

      Req.Test.stub(Magpie, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:page_request, conn.request_path})
        respond_page(conn, conn.request_path, Jason.decode!(body))
      end)

      assert [%{"name" => "a.jpg"}] =
               @client |> Magpie.Files.ListFolder.stream("/Photos") |> Enum.take(1)

      assert_received {:page_request, "/2/files/list_folder"}
      refute_received {:page_request, "/2/files/list_folder/continue"}
    end

    test "raises Magpie.Error when a page request fails" do
      Req.Test.stub(Magpie, fn conn ->
        conn
        |> Plug.Conn.put_status(409)
        |> Req.Test.json(%{"error_summary" => "path/not_found/"})
      end)

      assert_raise Magpie.Error, ~r/409/, fn ->
        @client |> Magpie.Files.ListFolder.stream("/missing") |> Enum.to_list()
      end
    end

    test "search_stream paginates over matches" do
      Req.Test.stub(Magpie, fn conn ->
        Req.Test.json(conn, %{"matches" => [%{"id" => 1}], "has_more" => false})
      end)

      assert [%{"id" => 1}] = @client |> Magpie.Files.search_stream("q") |> Enum.to_list()
    end

    test "FileRequests.stream and Sharing.list_folders_stream paginate their items" do
      Req.Test.stub(Magpie, fn conn ->
        case conn.request_path do
          "/2/file_requests/list_v2" ->
            Req.Test.json(conn, %{"file_requests" => [%{"id" => "fr1"}], "has_more" => false})

          "/2/sharing/list_folders" ->
            Req.Test.json(conn, %{"entries" => [%{"name" => "Shared"}]})
        end
      end)

      assert [%{"id" => "fr1"}] = @client |> Magpie.FileRequests.stream() |> Enum.to_list()

      assert [%{"name" => "Shared"}] =
               @client |> Magpie.Sharing.list_folders_stream() |> Enum.to_list()
    end

    defp respond_page(conn, "/2/files/list_folder", _body) do
      Req.Test.json(conn, %{
        "entries" => [%{"name" => "a.jpg"}, %{"name" => "b.jpg"}],
        "cursor" => "cursor-1",
        "has_more" => true
      })
    end

    defp respond_page(conn, "/2/files/list_folder/continue", %{"cursor" => "cursor-1"}) do
      Req.Test.json(conn, %{
        "entries" => [%{"name" => "c.jpg"}],
        "cursor" => "cursor-2",
        "has_more" => false
      })
    end
  end

  describe "Async.await/4" do
    test "passes through launches that completed synchronously" do
      launch = %{".tag" => "complete", "entries" => []}
      assert {:ok, ^launch} = Magpie.Async.await(@client, launch, fn _, _ -> flunk("no poll") end)
    end

    test "polls the check endpoint until the job completes" do
      counter = :counters.new(1, [])

      check = fn client, "job-1" ->
        assert client == @client
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          n when n <= 2 -> {:ok, %{".tag" => "in_progress"}}
          _ -> {:ok, %{".tag" => "complete", "entries" => []}}
        end
      end

      launch = %{".tag" => "async_job_id", "async_job_id" => "job-1"}

      assert {:ok, %{".tag" => "complete"}} =
               Magpie.Async.await(@client, launch, check, interval: 1)

      assert :counters.get(counter, 1) == 3
    end

    test "returns {:error, :timeout} when the deadline elapses" do
      check = fn _client, _id -> {:ok, %{".tag" => "in_progress"}} end

      assert {:error, :timeout} =
               Magpie.Async.await(@client, "job-1", check, interval: 5, timeout: 12)
    end

    test "hands back failed jobs and API errors untouched" do
      failed = fn _client, _id -> {:ok, %{".tag" => "failed", "failed" => %{}}} end
      assert {:ok, %{".tag" => "failed"}} = Magpie.Async.await(@client, "j", failed)

      api_error = fn _client, _id -> {:error, %Magpie.Error{status: 409, summary: "x"}} end
      assert {:error, %Magpie.Error{status: 409}} = Magpie.Async.await(@client, "j", api_error)
    end

    test "works end-to-end against a stubbed batch endpoint" do
      Req.Test.stub(Magpie, fn conn ->
        respond_batch(conn, conn.request_path)
      end)

      {:ok, launch} =
        Magpie.Files.MoveBatch.move_batch(@client, [%{"from_path" => "/a", "to_path" => "/b"}])

      assert {:ok, %{".tag" => "complete"}} =
               Magpie.Async.await(@client, launch, &Magpie.Files.MoveBatch.check/2, interval: 1)
    end

    defp respond_batch(conn, "/2/files/move_batch_v2"),
      do: Req.Test.json(conn, %{".tag" => "async_job_id", "async_job_id" => "job-9"})

    defp respond_batch(conn, "/2/files/move_batch/check_v2"),
      do: Req.Test.json(conn, %{".tag" => "complete", "entries" => []})
  end
end
