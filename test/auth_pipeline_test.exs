defmodule MagpieAuthPipelineTest do
  @moduledoc """
  How a client's token provider drives the request pipeline: bearer stamping,
  transparent refresh-and-replay on `expired_access_token`, and short-circuits.
  """
  use ExUnit.Case, async: true

  alias Magpie.Auth.TokenServer
  alias Magpie.Client

  defmodule RotatingProvider do
    @moduledoc false
    # Hands out the head of a list of tokens; a refresh drops it, exposing
    # the next one. The arg is the Agent holding the list.
    @behaviour Magpie.Auth.TokenProvider

    @impl true
    def fetch_token(agent), do: {:ok, Agent.get(agent, &hd/1)}

    @impl true
    def refresh_token(agent) do
      Agent.update(agent, fn
        [last] -> [last]
        [_stale | rest] -> rest
      end)

      {:ok, Agent.get(agent, &hd/1)}
    end
  end

  defmodule BrokenProvider do
    @moduledoc false
    # Every callback fails, as a provider whose storage is unreachable would.
    @behaviour Magpie.Auth.TokenProvider

    @impl true
    def fetch_token(_arg), do: {:error, error()}

    @impl true
    def refresh_token(_arg), do: {:error, error()}

    defp error do
      %Magpie.Error{
        status: 400,
        summary: "invalid_grant",
        body: %{"error" => "invalid_grant", "error_description" => "refresh token is invalid"}
      }
    end
  end

  defmodule StaleProvider do
    @moduledoc false
    # Hands out a token Dropbox will reject, and cannot refresh it.
    @behaviour Magpie.Auth.TokenProvider

    @impl true
    def fetch_token(_arg), do: {:ok, "sl.EXPIRED"}

    @impl true
    defdelegate refresh_token(arg), to: BrokenProvider
  end

  describe "authentication" do
    test "the request carries the token handed out by the provider" do
      client = rotating_client(["sl.CURRENT"])

      Req.Test.stub(Magpie, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sl.CURRENT"]
        Req.Test.json(conn, %{"metadata" => %{"name" => "Photos"}})
      end)

      assert {:ok, %{"metadata" => _}} = Magpie.Files.create_folder(client, "/Photos")
    end

    test "a client built by hand still authenticates with its access token" do
      Req.Test.stub(Magpie, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer legacy-token"]
        Req.Test.json(conn, %{"result" => "ping"})
      end)

      assert {:ok, _} = Magpie.Check.user(%Client{access_token: "legacy-token"})
    end

    test "a credential-less client sends no authorization header" do
      Req.Test.stub(Magpie, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        Req.Test.json(conn, %{"result" => "ping"})
      end)

      assert {:ok, _} = Magpie.Check.user(Client.new())
    end

    test "a provider failure short-circuits before any request" do
      client = Client.new(token_provider: {BrokenProvider, :unused})
      stub_counting_requests(%{"result" => "ping"})

      assert {:error, %Magpie.Error{status: 400, summary: "invalid_grant"}} =
               Magpie.Check.user(client)

      assert request_count() == 0
    end

    test "a provider failure short-circuits download requests too" do
      client = Client.new(token_provider: {BrokenProvider, :unused})
      stub_counting_requests(%{"result" => "ping"})

      assert {:error, %Magpie.Error{status: 400, summary: "invalid_grant"}} =
               Magpie.Files.download(client, "/backup.zip")

      assert request_count() == 0
    end
  end

  describe "expired access token" do
    test "is refreshed and the request replayed once" do
      client = rotating_client(["sl.EXPIRED", "sl.FRESH"])

      Req.Test.expect(Magpie, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sl.EXPIRED"]
        expired(conn)
      end)

      Req.Test.expect(Magpie, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sl.FRESH"]

        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{"path" => "/Photos"}

        Req.Test.json(conn, %{"metadata" => %{"name" => "Photos"}})
      end)

      assert {:ok, %{"metadata" => %{"name" => "Photos"}}} =
               Magpie.Files.create_folder(client, "/Photos")

      Req.Test.verify!()
    end

    test "propagates the error when the replay is rejected as well" do
      client = rotating_client(["sl.EXPIRED", "sl.ALSO_EXPIRED"])
      test_pid = self()

      Req.Test.stub(Magpie, fn conn ->
        send(test_pid, :request)
        expired(conn)
      end)

      assert {:error, %Magpie.Error{status: 401, summary: "expired_access_token/..."}} =
               Magpie.Files.create_folder(client, "/Photos")

      assert request_count() == 2
    end

    test "propagates a failed refresh instead of the 401" do
      client = Client.new(token_provider: {StaleProvider, :unused})
      stub_counting_requests(:expired)

      assert {:error, %Magpie.Error{status: 400, summary: "invalid_grant"}} =
               Magpie.Files.create_folder(client, "/Photos")

      assert request_count() == 1
    end

    test "other 401s are not retried" do
      client = rotating_client(["sl.REVOKED", "sl.FRESH"])
      test_pid = self()

      Req.Test.stub(Magpie, fn conn ->
        send(test_pid, :request)

        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{
          "error_summary" => "invalid_access_token/...",
          "error" => %{".tag" => "invalid_access_token"}
        })
      end)

      assert {:error, %Magpie.Error{status: 401, summary: "invalid_access_token/..."}} =
               Magpie.Files.create_folder(client, "/Photos")

      assert request_count() == 1
    end

    test "a 401 with an unexpected body shape is not retried" do
      client = rotating_client(["sl.EXPIRED", "sl.FRESH"])
      test_pid = self()

      Req.Test.stub(Magpie, fn conn ->
        send(test_pid, :request)

        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(["unexpected"])
      end)

      assert {:error, %Magpie.Error{status: 401, summary: nil}} =
               Magpie.Files.create_folder(client, "/Photos")

      assert request_count() == 1
    end

    test "is detected on content endpoints, which answer in plain text" do
      client = rotating_client(["sl.EXPIRED", "sl.FRESH"])

      Req.Test.expect(Magpie, fn conn ->
        Plug.Conn.send_resp(conn, 401, ~s|{"error_summary": "expired_access_token/..."}|)
      end)

      Req.Test.expect(Magpie, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sl.FRESH"]
        Plug.Conn.send_resp(conn, 200, "file-contents")
      end)

      assert {:ok, %{body: "file-contents"}} = Magpie.Files.download(client, "/backup.zip")

      Req.Test.verify!()
    end

    @tag :tmp_dir
    test "streamed upload bodies are never replayed", %{tmp_dir: dir} do
      local = Path.join(dir, "upload.bin")
      File.write!(local, "payload")

      client = rotating_client(["sl.EXPIRED", "sl.FRESH"])
      stub_counting_requests(:expired)

      assert {:error, %Magpie.Error{status: 401, summary: "expired_access_token/..."}} =
               Magpie.Files.upload(client, "/upload.bin", local)

      assert request_count() == 1
    end

    test "a static token client retries once and then gives up" do
      client = Client.new("fake-token")
      test_pid = self()

      Req.Test.stub(Magpie, fn conn ->
        send(test_pid, :request)
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fake-token"]
        expired(conn)
      end)

      assert {:error, %Magpie.Error{status: 401, summary: "expired_access_token/..."}} =
               Magpie.Check.user(client)

      assert request_count() == 2
    end
  end

  describe "Client.new/1" do
    test "wraps a refresh token in a linked token server" do
      client =
        Client.new(
          refresh_token: "RT",
          app_key: "APP_KEY",
          app_secret: "APP_SECRET",
          refresh_margin: 60
        )

      assert {TokenServer, server} = client.token_provider
      assert Process.alive?(server)

      Req.Test.stub(Magpie, fn conn ->
        case conn.request_path do
          "/oauth2/token" ->
            Req.Test.json(conn, %{"access_token" => "sl.FRESH", "expires_in" => 14_400})

          "/2/check/user" ->
            assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sl.FRESH"]
            Req.Test.json(conn, %{"result" => "ping"})
        end
      end)

      Req.Test.allow(Magpie, self(), server)

      assert {:ok, %{"result" => "ping"}} = Magpie.Check.user(client)
    end

    test "reuses an already started named token server" do
      name = :"token_server_#{System.unique_integer([:positive])}"
      opts = [name: name, refresh_token: "RT", app_key: "APP_KEY", pkce: true]

      first = Client.new(opts)
      second = Client.new(opts)

      assert first.token_provider == second.token_provider
    end

    test "rejects options it cannot make a provider out of" do
      assert_raise ArgumentError, ~r/:token_provider or a :refresh_token/, fn ->
        Client.new(app_key: "APP_KEY")
      end

      assert_raise ArgumentError, ~r/{module, arg} tuple/, fn ->
        Client.new(token_provider: MyApp.DropboxTokens)
      end
    end
  end

  defp rotating_client(tokens) do
    agent = start_supervised!({Agent, fn -> tokens end})

    Client.new(token_provider: {RotatingProvider, agent})
  end

  defp stub_counting_requests(body) do
    test_pid = self()

    Req.Test.stub(Magpie, fn conn ->
      send(test_pid, :request)

      case body do
        :expired -> expired(conn)
        body -> Req.Test.json(conn, body)
      end
    end)
  end

  defp expired(conn) do
    conn
    |> Plug.Conn.put_status(401)
    |> Req.Test.json(%{
      "error_summary" => "expired_access_token/...",
      "error" => %{".tag" => "expired_access_token"}
    })
  end

  defp request_count(count \\ 0) do
    receive do
      :request -> request_count(count + 1)
    after
      0 -> count
    end
  end
end
