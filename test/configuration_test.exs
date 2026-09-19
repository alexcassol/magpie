defmodule Magpie.ConfigurationTest do
  use ExUnit.Case, async: true
  alias Magpie.{Client, Error, FileMetadata, Storage, TimeoutError}

  defmodule InspectTimeouts do
    def run(request) do
      assert request.options.receive_timeout == 5
      assert request.options.request_timeout in 1..1000
      assert request.options.pool_timeout in 1..1000
      {request, Req.Response.new(status: 200, body: %{".tag" => "file", "name" => "a"})}
    end
  end

  defmodule InspectFinchTimeouts do
    def run(request) do
      assert request.options.receive_timeout == 15_000
      assert request.options.pool_timeout == 5_000
      assert request.options.finch[:receive_timeout] in 1..20_000
      assert request.options.finch[:request_timeout] == 5
      {request, Req.Response.new(status: 200, body: %{".tag" => "file", "name" => "a"})}
    end
  end

  test "client and operation configuration isolate concurrent accounts" do
    for {label, token} <- [{"one", "secret-one"}, {"two", "secret-two"}] do
      Req.Test.stub(label, fn conn ->
        assert conn.host == label <> ".example"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> token]
        assert Plug.Conn.get_req_header(conn, "x-local") == [label]
        Req.Test.json(conn, %{".tag" => "file", "name" => label})
      end)
    end

    clients =
      for label <- ["one", "two"] do
        Client.new("secret-" <> label,
          base_url: "https://#{label}.example/2",
          req_options: [plug: {Req.Test, label}, headers: [{"x-local", label}]],
          retry: false
        )
      end

    results = clients |> Task.async_stream(&Storage.stat(&1, "/a")) |> Enum.to_list()

    assert [{:ok, {:ok, %FileMetadata{name: "one"}}}, {:ok, {:ok, %FileMetadata{name: "two"}}}] =
             results

    Req.Test.stub(:override, fn conn ->
      assert conn.host == "override.example"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer secret-one"]
      Req.Test.json(conn, %{".tag" => "file", "name" => "override"})
    end)

    assert {:ok, %FileMetadata{name: "override"}} =
             Storage.stat(hd(clients), "/a",
               request: [
                 base_url: "https://override.example/2",
                 req_options: [plug: {Req.Test, :override}]
               ]
             )

    assert {:ok, %FileMetadata{name: "one"}} = Storage.stat(hd(clients), "/a")
  end

  test "client config separates RPC from content endpoints and preserves API headers" do
    client =
      Client.new("token",
        base_url: "https://rpc.example/2",
        upload_url: "https://bytes.example/2/",
        req_options: [headers: [{"x-local", "value"}]]
      )

    Req.Test.stub(Magpie, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-local") == ["value"]

      if String.ends_with?(conn.request_path, "upload") do
        assert conn.host == "bytes.example"
        assert [arg] = Plug.Conn.get_req_header(conn, "dropbox-api-arg")
        assert Jason.decode!(arg)["path"] == "/a"
      else
        assert conn.host == "rpc.example"
      end

      Req.Test.json(conn, %{".tag" => "file", "name" => "a"})
    end)

    assert {:ok, _} = Storage.put(client, "/a", {:binary, "a"})
    assert {:ok, _} = Storage.stat(client, "/a")
  end

  test "client and operation retry policies replace the global policy" do
    Req.Test.stub(Magpie, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "0")
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"error_summary" => "too_many_requests"})
    end)

    client = Client.new("token", retry: [max_retries: 2, delay: 0, log_level: false])

    assert {:error, %Error{attempts: 3, retry_after: 0, endpoint: "/files/get_metadata"}} =
             Storage.stat(client, "/a")

    assert {:error, %Error{attempts: 1}} = Storage.stat(client, "/a", request: [retry: false])

    assert {:error, %Error{attempts: 2}} =
             Storage.stat(client, "/a",
               request: [retry: [max_retries: 1, delay: 0, log_level: false]]
             )

    assert {:error, %Error{attempts: 1}} = Storage.put(client, "/a", {:binary, "a"})
  end

  test "retry-after exceeding the remaining budget returns the original error immediately" do
    Req.Test.stub(Magpie, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "3600")
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"error_summary" => "too_many_requests"})
    end)

    client = Client.new("token", retry: [max_retries: 3, log_level: false], timeout: 500)
    assert {:error, %Error{attempts: 1, retry_after: 3_600_000}} = Storage.stat(client, "/a")
  end

  test "a zero budget prevents requests and follows normal, bang and lazy contracts" do
    Req.Test.stub(Magpie, fn _ -> flunk("budget must be checked before the request") end)
    client = Client.new("token", timeout: 0)
    assert {:error, %TimeoutError{endpoint: "/files/get_metadata"}} = Storage.stat(client, "/a")
    assert_raise TimeoutError, fn -> Storage.stat!(client, "/a") end
    assert {:error, %TimeoutError{}} = Storage.list(client)
    assert_raise TimeoutError, fn -> client |> Storage.stream() |> Enum.to_list() end
  end

  test "execution budget survives pagination and starts when the stream is enumerated" do
    Req.Test.stub(Magpie, fn conn ->
      assert conn.request_path == "/2/files/list_folder"

      Req.Test.json(conn, %{
        "entries" => [%{".tag" => "file", "name" => "a"}],
        "cursor" => "c",
        "has_more" => true
      })
    end)

    stream = Storage.stream(Client.new("token", timeout: 50))
    Process.sleep(60)
    assert [%FileMetadata{name: "a"}] = Enum.take(stream, 1)
    assert_raise TimeoutError, fn -> Enum.each(stream, fn _ -> Process.sleep(60) end) end
  end

  test "budget caps per-attempt timeouts without increasing a smaller client timeout" do
    client =
      Client.new("token",
        timeout: 1000,
        req_options: [plug: nil, adapter: InspectTimeouts, receive_timeout: 5]
      )

    assert {:ok, %FileMetadata{}} = Storage.stat(client, "/a")
  end

  @tag :tmp_dir
  test "timed out download preserves destination and cleans the temporary file", %{tmp_dir: dir} do
    destination = Path.join(dir, "a")
    File.write!(destination, "original")

    Req.Test.stub(Magpie, fn conn ->
      Process.sleep(30)
      Plug.Conn.send_resp(conn, 200, "new")
    end)

    assert {:error, %TimeoutError{}} =
             Storage.download(Client.new("token", timeout: 10), "/a", destination)

    assert File.read!(destination) == "original"
    assert Path.wildcard(destination <> ".magpie-*.part") == []
  end

  test "invalid configuration never echoes supplied values" do
    for opts <- [
          [retry: :secret],
          [timeout: "secret"],
          [req_options: "secret"],
          [scopes: "secret"],
          [retry: [delay: -1]],
          [retry: [max_retries: -1]],
          [base_url: "secret"]
        ] do
      error = assert_raise ArgumentError, fn -> Client.new("secret", opts) end
      refute Exception.message(error) =~ "secret"
    end

    assert_raise ArgumentError, fn -> Client.new(access_token: "secret", typo: true) end
    assert_raise ArgumentError, fn -> Client.new("secret", timeout: 1, timeout: 2) end
  end

  test "credential constructors and local scope diagnosis preserve known and unknown states" do
    assert Client.new(access_token: "token").token_provider == {Magpie.Auth.StaticToken, "token"}
    assert Client.missing_scopes(Client.new("token"), ["files.content.write"]) == :unknown

    client =
      Client.new(
        token_provider: {Magpie.Auth.StaticToken, "token"},
        scopes: ["files.content.read"]
      )

    assert Client.missing_scopes(client, ["files.content.read", "files.content.write"]) == [
             "files.content.write"
           ]

    refute inspect(Client.with_options(client, req_options: [headers: [{"secret", "hidden"}]])) =~
             "hidden"
  end

  test "error diagnostics normalize headers and exclude response data" do
    body = %{
      "error" => %{".tag" => "missing_scope", "required_scope" => "files.content.write"},
      "secret" => "credential"
    }

    error = Error.new(401, body, [{"Retry-After", "12"}, {"X-Dropbox-Request-Id", "request-1"}])
    assert error.retry_after == 12_000
    assert error.request_id == "request-1"
    assert Error.required_scope(error) == "files.content.write"
    refute inspect(Error.diagnostics(error)) =~ "credential"

    for value <- ["invalid", "12s", "-2", "", nil] do
      assert Error.new(429, %{}, %{"retry-after" => [value]}).retry_after == nil
    end

    assert is_integer(
             Error.new(429, %{}, %{"retry-after" => ["Wed, 21 Oct 2099 07:28:00 GMT"]}).retry_after
           )
  end

  test "request options never become Dropbox listing arguments" do
    Req.Test.stub(Magpie, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"path" => "", "recursive" => true}
      Req.Test.json(conn, %{"entries" => [], "cursor" => "c", "has_more" => false})
    end)

    assert {:ok, []} =
             Storage.list(Client.new("token"), "", recursive: true, request: [retry: false])
  end

  test "refresh-token clients isolate OAuth configuration from content configuration" do
    Req.Test.stub(:oauth_client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert URI.decode_query(body)["refresh_token"] == "refresh-secret"

      Req.Test.json(conn, %{
        "access_token" => "fresh-secret",
        "expires_in" => 3600,
        "token_type" => "bearer"
      })
    end)

    client =
      Client.new(
        refresh_token: "refresh-secret",
        app_key: "key",
        pkce: true,
        oauth_req_options: [plug: {Req.Test, :oauth_client}],
        req_options: [plug: {Req.Test, :content_client}]
      )

    {_, pid} = Client.token_provider(client)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    Req.Test.allow(:oauth_client, self(), pid)

    Req.Test.stub(:content_client, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fresh-secret"]
      Req.Test.json(conn, %{".tag" => "file", "name" => "a"})
    end)

    assert {:ok, %FileMetadata{}} = Storage.stat(client, "/a")
  end

  test "authentication replay contributes to terminal attempt diagnostics" do
    client = Client.new(token_provider: {Magpie.Auth.StaticToken, "token"})

    Req.Test.stub(Magpie, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error_summary" => "expired_access_token/.."})
    end)

    assert {:error, %Error{attempts: 2, endpoint: "/files/get_metadata"}} =
             Storage.stat(client, "/a")
  end

  test "budget respects native defaults and nested Finch overrides" do
    client =
      Client.new("token",
        timeout: 20_000,
        req_options: [
          plug: nil,
          adapter: InspectFinchTimeouts,
          finch: [receive_timeout: :infinity, request_timeout: 5]
        ]
      )

    assert {:ok, _} = Storage.stat(client, "/a")
  end

  test "an upload shares its budget across session requests" do
    parent = self()

    Req.Test.stub(Magpie, fn conn ->
      send(parent, {:session_request, conn.request_path})

      case conn.request_path do
        "/2/files/upload_session/start" -> Req.Test.json(conn, %{"session_id" => "s"})
        "/2/files/upload_session/append_v2" -> Req.Test.json(conn, nil)
        _ -> flunk("must not commit after budget exhaustion")
      end
    end)

    client = Client.new("token", timeout: 100)

    assert {:error, %TimeoutError{}} =
             Storage.put(client, "/a", {:binary, "abcdef"},
               session_threshold: 0,
               chunk_size: 2,
               progress: fn _, _ -> Process.sleep(110) end
             )

    assert_receive {:session_request, "/2/files/upload_session/start"}
    assert_receive {:session_request, "/2/files/upload_session/append_v2"}
    refute_receive {:session_request, _}
  end
end
