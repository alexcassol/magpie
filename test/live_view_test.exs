defmodule Magpie.LiveViewTest do
  @moduledoc """
  Tests for the external uploader: the presign call mints a one-time link
  committed to a fixed path, and refuses entries Dropbox could not accept.
  """
  use ExUnit.Case, async: true

  alias Magpie.Client
  alias Magpie.LiveView

  @client Client.new("fake-token")
  @link "https://content.dropboxapi.com/apitul/1/abc"

  defp entry(attrs \\ []) do
    Enum.into(attrs, %{client_name: "avatar.png", client_size: 1024})
  end

  test "returns LiveView external uploader metadata" do
    test_pid = self()

    Req.Test.stub(Magpie, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:call, conn.request_path, Jason.decode!(body)})
      Req.Test.json(conn, %{"link" => @link})
    end)

    assert {:ok, meta, :socket} =
             LiveView.presign_upload(@client, entry(), :socket, path: "/Avatars/a.png")

    assert meta == %{uploader: "Magpie", url: @link, path: "/Avatars/a.png"}

    assert_received {:call, "/2/files/get_temporary_upload_link", body}
    assert body["duration"] == 14_400

    assert body["commit_info"] == %{
             "path" => "/Avatars/a.png",
             "mode" => "add",
             "autorename" => true,
             "mute" => false
           }
  end

  test "defaults the path to the client filename at the root" do
    Req.Test.stub(Magpie, fn conn -> Req.Test.json(conn, %{"link" => @link}) end)

    assert {:ok, %{path: "/avatar.png"}, :socket} =
             LiveView.presign_upload(@client, entry(), :socket)
  end

  test "passes :duration and commit options through" do
    test_pid = self()

    Req.Test.stub(Magpie, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(body)})
      Req.Test.json(conn, %{"link" => @link})
    end)

    assert {:ok, _meta, :socket} =
             LiveView.presign_upload(@client, entry(), :socket,
               duration: 60,
               mode: "overwrite",
               autorename: false
             )

    assert_received {:body, body}
    assert body["duration"] == 60
    assert body["commit_info"]["mode"] == "overwrite"
    assert body["commit_info"]["autorename"] == false
  end

  test "refuses entries above the 150 MB single-request limit without calling Dropbox" do
    Req.Test.stub(Magpie, fn _conn -> flunk("should not have hit the API") end)

    big = entry(client_size: 150 * 1024 * 1024 + 1)

    assert {:error, %{error: "too_large_for_temporary_link"}, :socket} =
             LiveView.presign_upload(@client, big, :socket)
  end

  test "surfaces a Dropbox error as an :error tuple LiveView understands" do
    Req.Test.stub(Magpie, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error_summary" => "path/malformed_path/"})
    end)

    assert {:error, %{error: "path/malformed_path/"}, :socket} =
             LiveView.presign_upload(@client, entry(), :socket, path: "bad")
  end
end
