defmodule Magpie.LiveView.UploadWriterTest do
  @moduledoc """
  Tests for the LiveView upload writer: chunks are buffered to `:chunk_size`
  before each append, and the tail rides along with the finish call.
  """
  use ExUnit.Case, async: true

  alias Magpie.Client
  alias Magpie.LiveView.UploadWriter

  @client Client.new("fake-token")

  defp opts(extra \\ []), do: Keyword.merge([client: @client, path: "/report.pdf"], extra)

  defp stub_session(test_pid) do
    Req.Test.stub(Magpie, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      arg = conn |> Plug.Conn.get_req_header("dropbox-api-arg") |> decode_arg()
      send(test_pid, {:call, conn.request_path, arg, body})
      respond(conn, conn.request_path)
    end)
  end

  defp decode_arg([arg]), do: Jason.decode!(arg)
  defp decode_arg([]), do: %{}

  defp respond(conn, "/2/files/upload_session/start"),
    do: Req.Test.json(conn, %{"session_id" => "sess-1"})

  defp respond(conn, "/2/files/upload_session/append_v2"),
    do: Req.Test.json(conn, nil)

  defp respond(conn, "/2/files/upload_session/finish"),
    do: Req.Test.json(conn, %{"name" => "report.pdf"})

  test "buffers chunks up to :chunk_size and commits the tail on close" do
    stub_session(self())

    assert {:ok, state} = UploadWriter.init(opts(chunk_size: 5))
    assert_received {:call, "/2/files/upload_session/start", _, ""}

    # Nothing goes out until the buffer reaches chunk_size.
    assert {:ok, state} = UploadWriter.write_chunk("012", state)
    refute_received {:call, "/2/files/upload_session/append_v2", _, _}

    assert {:ok, state} = UploadWriter.write_chunk("3456789AB", state)
    assert_received {:call, "/2/files/upload_session/append_v2", %{"cursor" => c1}, "01234"}
    assert c1["offset"] == 0
    assert_received {:call, "/2/files/upload_session/append_v2", %{"cursor" => c2}, "56789"}
    assert c2["offset"] == 5

    assert {:ok, state} = UploadWriter.close(state, :done)

    assert_received {:call, "/2/files/upload_session/finish", arg, "AB"}
    assert arg["cursor"]["offset"] == 10
    assert arg["commit"]["path"] == "/report.pdf"

    assert UploadWriter.meta(state) == %{
             path: "/report.pdf",
             metadata: %{"name" => "report.pdf"}
           }
  end

  test "an empty entry still commits a zero-byte file" do
    stub_session(self())

    assert {:ok, state} = UploadWriter.init(opts())
    assert {:ok, _state} = UploadWriter.close(state, :done)

    assert_received {:call, "/2/files/upload_session/finish", arg, ""}
    assert arg["cursor"]["offset"] == 0
  end

  test "a cancelled upload never commits" do
    stub_session(self())

    assert {:ok, state} = UploadWriter.init(opts())
    assert {:ok, state} = UploadWriter.write_chunk("abc", state)
    assert {:ok, _state} = UploadWriter.close(state, :cancel)

    refute_received {:call, "/2/files/upload_session/finish", _, _}
  end

  test "a failing append surfaces the error and keeps the state" do
    Req.Test.stub(Magpie, fn conn ->
      case conn.request_path do
        "/2/files/upload_session/start" ->
          Req.Test.json(conn, %{"session_id" => "sess-1"})

        "/2/files/upload_session/append_v2" ->
          conn
          |> Plug.Conn.put_status(409)
          |> Req.Test.json(%{"error_summary" => "incorrect_offset/"})
      end
    end)

    assert {:ok, state} = UploadWriter.init(opts(chunk_size: 2))

    assert {:error, %Magpie.Error{status: 409}, failed} = UploadWriter.write_chunk("abcd", state)

    # The offset never advanced and the bytes are still buffered — LiveView
    # aborts the entry from here, but nothing was silently dropped.
    assert failed.offset == 0
    assert failed.buffer == "abcd"
  end

  test "a failing start aborts before any bytes are read" do
    Req.Test.stub(Magpie, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error_summary" => "expired_access_token/"})
    end)

    assert {:error, %Magpie.Error{status: 401}} = UploadWriter.init(opts())
  end
end
