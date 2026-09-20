defmodule VerifiedBackup.DropboxFixture do
  import ExUnit.Assertions

  def client do
    Magpie.Client.new("offline-token",
      req_options: [plug: {Req.Test, __MODULE__}],
      retry: false
    )
  end

  def metadata(path, body, rev \\ "00000000001", id \\ "id:fixture") do
    %{
      ".tag" => "file",
      "id" => id,
      "name" => Path.basename(path),
      "path_display" => path,
      "path_lower" => String.downcase(path),
      "rev" => rev,
      "size" => byte_size(body),
      "content_hash" => Magpie.Metadata.content_hash(body)
    }
  end

  def folder(path),
    do: %{
      ".tag" => "folder",
      "id" => "id:" <> path,
      "name" => Path.basename(path),
      "path_display" => path,
      "path_lower" => String.downcase(path)
    }

  def rpc(route, expected, response, status \\ 200) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/2/files/" <> route
      body = conn |> Req.Test.raw_body() |> Jason.decode!()
      assert Map.take(body, Map.keys(expected)) == expected
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(response)
    end)
  end

  def download(path, body) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/2/files/download"
      assert arg(conn)["path"] == path

      conn
      |> Plug.Conn.put_resp_content_type("application/octet-stream")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  def upload(check, rev \\ "00000000002") do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/2/files/upload"
      args = arg(conn)
      body = Req.Test.raw_body(conn)
      check.(args, body)
      Req.Test.json(conn, metadata(args["path"], body, rev))
    end)
  end

  def arg(conn),
    do: conn |> Plug.Conn.get_req_header("dropbox-api-arg") |> hd() |> Jason.decode!()

  def verify!, do: Req.Test.verify!(__MODULE__)
end
