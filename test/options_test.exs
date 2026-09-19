defmodule Magpie.OptionsTest do
  use ExUnit.Case, async: true
  alias Magpie.{Client, Files, Storage}
  @client Client.new("token")

  test "invalid upload options fail before any request or local file read" do
    Req.Test.stub(Magpie, fn _ -> flunk("must validate before sending") end)

    for opts <- [
          [mode: "invalid"],
          [if_rev: ""],
          [autorename: "false"],
          [mute: 1],
          [verify: :yes],
          [skip_unchanged: 1],
          [chunk_size: 0],
          [chunk_size: -1],
          [session_threshold: -1],
          [session_threshold: 157_286_401],
          [progress: :invalid],
          [verfiy: true],
          [request: false]
        ] do
      assert_raise ArgumentError, fn -> Storage.put(@client, "/a", {:file, "/missing"}, opts) end
    end

    assert_raise ArgumentError, fn ->
      Files.upload_file(@client, "/a", "/missing", chunk_size: 0)
    end

    assert_raise ArgumentError, fn -> Files.upload_data(@client, "/a", "x", mode: :bad) end
    assert_raise ArgumentError, fn -> Files.upload_stream(@client, "/a", [], mute: :bad) end
  end

  @tag :tmp_dir
  test "download options are validated before creating directories", %{tmp_dir: dir} do
    path = Path.join([dir, "new", "file"])

    assert_raise ArgumentError, fn ->
      Storage.download(@client, "/a", path, mkdir_p: true, size: -1)
    end

    refute File.exists?(Path.dirname(path))
  end

  test "every Storage operation rejects ignored options and invalid values" do
    calls = [
      fn -> Storage.get(@client, "/a", with_headers: "true") end,
      fn -> Storage.delete(@client, "/a", parent_rev: 3) end,
      fn -> Storage.exists?(@client, "/a", include_deleted: 1) end,
      fn -> Storage.stat(@client, "/a", unknown: true) end,
      fn -> Storage.list(@client, "", limit: 0) end,
      fn -> Storage.stream(@client, "", recursive: "true") end,
      fn -> Storage.url(@client, "/a", unknown: true) end,
      fn -> Storage.upload_url(@client, "/a", duration: 14_401) end,
      fn -> Storage.copy(@client, "/a", "/b", autorename: true) end,
      fn -> Storage.move(@client, "/a", "/b", unknown: true) end,
      fn -> Storage.mkdir(@client, "/a", unknown: true) end,
      fn -> Storage.put_many(@client, [], max_concurrency: 0) end,
      fn -> Storage.delete_many(@client, [], timeout: -1) end
    ]

    for call <- calls, do: assert_raise(ArgumentError, call)
  end

  test "write defaults remain add with autorename; revision still takes precedence" do
    parent = self()

    Req.Test.stub(Magpie, fn conn ->
      arg = conn |> Plug.Conn.get_req_header("dropbox-api-arg") |> hd() |> Jason.decode!()
      send(parent, {:commit, arg})
      Req.Test.json(conn, %{".tag" => "file", "name" => "a"})
    end)

    assert {:ok, _} = Storage.put(@client, "/a", {:binary, "x"})
    assert_receive {:commit, %{"mode" => "add", "autorename" => true}}

    assert {:ok, _} =
             Storage.put(@client, "/a", {:binary, "x"},
               if_rev: "r",
               mode: "overwrite",
               skip_unchanged: true
             )

    assert_receive {:commit, %{"mode" => %{".tag" => "update", "update" => "r"}}}
  end

  test "batch per-item invalid options stay isolated while common invalid options raise" do
    Req.Test.stub(Magpie, fn conn -> Req.Test.json(conn, %{".tag" => "file", "name" => "ok"}) end)

    assert {:ok, [{"/bad", {:error, %ArgumentError{}}}, {"/ok", {:ok, _}}]} =
             Storage.put_many(@client, [
               {"/bad", {:binary, "a"}, [verify: 1]},
               {"/ok", {:binary, "a"}}
             ])

    assert_raise ArgumentError, fn -> Storage.put_many(@client, [], verify: 1) end
  end
end
