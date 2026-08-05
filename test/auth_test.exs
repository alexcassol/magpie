defmodule MagpieAuthTest do
  @moduledoc """
  OAuth 2 flow helpers: authorization URL, PKCE, code exchange and refresh.
  """
  use ExUnit.Case, async: true

  alias Magpie.Auth
  alias Magpie.Auth.Token

  doctest Magpie.Auth
  doctest Magpie.Auth.Token
  doctest Magpie.Auth.StaticToken
  doctest Magpie.Client
  doctest Magpie.Error

  @authorize_url "https://www.dropbox.com/oauth2/authorize"

  describe "authorize_url/2" do
    test "asks for an offline code grant by default" do
      assert Auth.authorize_url("APP_KEY") ==
               @authorize_url <> "?client_id=APP_KEY&response_type=code&token_access_type=offline"
    end

    test "includes redirect_uri, state and space-separated scopes" do
      url =
        Auth.authorize_url("APP_KEY",
          redirect_uri: "https://myapp.com/dropbox/callback",
          state: "csrf-42",
          scope: ["files.content.write", "files.content.read"]
        )

      assert %{
               "client_id" => "APP_KEY",
               "response_type" => "code",
               "token_access_type" => "offline",
               "redirect_uri" => "https://myapp.com/dropbox/callback",
               "state" => "csrf-42",
               "scope" => "files.content.write files.content.read"
             } == url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    end

    test "accepts an already joined scope string" do
      assert Auth.authorize_url("APP_KEY", scope: "account_info.read") =~
               "&scope=account_info.read"
    end

    test "a code challenge implies the S256 method" do
      {_verifier, challenge} = Auth.pkce_pair()

      url = Auth.authorize_url("APP_KEY", code_challenge: challenge)

      assert %{"code_challenge" => ^challenge, "code_challenge_method" => "S256"} =
               url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    end

    test "token_access_type can be overridden" do
      assert Auth.authorize_url("APP_KEY", token_access_type: "online") =~
               "&token_access_type=online"
    end

    test "percent-encodes reserved characters" do
      url = Auth.authorize_url("APP KEY&x", redirect_uri: "https://myapp.com/cb?a=b")

      assert url =~ "client_id=APP%20KEY%26x"
      assert url =~ "redirect_uri=https%3A%2F%2Fmyapp.com%2Fcb%3Fa%3Db"
    end

    test "extra_params are appended after the standard params and encoded" do
      url =
        Auth.authorize_url("APP_KEY",
          redirect_uri: "https://myapp.com/cb",
          extra_params: [force_reapprove: true, locale: "pt_BR", require_role: :personal]
        )

      # booleans and atoms render as strings; order is standard-then-extra
      assert url =~ "myapp.com%2Fcb&force_reapprove=true&locale=pt_BR&require_role=personal"
    end

    test "extra_params accepts a map and percent-encodes values" do
      url = Auth.authorize_url("APP_KEY", extra_params: %{"locale" => "pt BR"})

      assert url =~ "&locale=pt%20BR"
    end

    test "extra_params cannot override params the function sets" do
      assert_raise ArgumentError, ~r/"client_id"/, fn ->
        Auth.authorize_url("APP_KEY", extra_params: [client_id: "EVIL"])
      end

      assert_raise ArgumentError, ~r/"token_access_type"/, fn ->
        Auth.authorize_url("APP_KEY", extra_params: %{"token_access_type" => "online"})
      end

      assert_raise ArgumentError, ~r/"code_challenge"/, fn ->
        Auth.authorize_url("APP_KEY",
          code_challenge: "abc",
          extra_params: [code_challenge: "evil"]
        )
      end

      assert_raise ArgumentError, ~r/"state"/, fn ->
        Auth.authorize_url("APP_KEY", state: "csrf", extra_params: [state: "evil"])
      end
    end

    test "no extra_params leaves the URL byte-identical" do
      assert Auth.authorize_url("APP_KEY", extra_params: []) == Auth.authorize_url("APP_KEY")
    end
  end

  describe "pkce_pair/0" do
    test "verifiers are random, long enough and use the unreserved charset" do
      {verifier, _challenge} = Auth.pkce_pair()
      {other_verifier, _} = Auth.pkce_pair()

      assert byte_size(verifier) in 43..128
      assert verifier =~ ~r/\A[A-Za-z0-9\-._~]+\z/
      refute verifier == other_verifier
    end

    test "the challenge is the S256 digest of the verifier" do
      {verifier, challenge} = Auth.pkce_pair()

      expected =
        :sha256
        |> :crypto.hash(verifier)
        |> Base.url_encode64(padding: false)

      assert challenge == expected
    end

    test "matches the RFC 7636 test vector" do
      assert Auth.pkce_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") ==
               "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    end
  end

  describe "exchange_code/3" do
    test "posts the code with the app secret and returns the token set" do
      Req.Test.stub(Magpie, fn conn ->
        assert conn.request_path == "/oauth2/token"
        assert conn.method == "POST"

        assert Plug.Conn.get_req_header(conn, "content-type") == [
                 "application/x-www-form-urlencoded"
               ]

        assert %{
                 "code" => "AUTH_CODE",
                 "grant_type" => "authorization_code",
                 "client_id" => "APP_KEY",
                 "client_secret" => "APP_SECRET",
                 "redirect_uri" => "https://myapp.com/cb"
               } == read_form(conn)

        Req.Test.json(conn, %{
          "access_token" => "sl.NEW",
          "refresh_token" => "RT",
          "expires_in" => 14_400,
          "token_type" => "bearer",
          "scope" => "files.content.read files.content.write",
          "account_id" => "dbid:AAA",
          "uid" => "329807743"
        })
      end)

      assert {:ok, token} =
               Auth.exchange_code("APP_KEY", "AUTH_CODE",
                 app_secret: "APP_SECRET",
                 redirect_uri: "https://myapp.com/cb"
               )

      assert %Token{
               access_token: "sl.NEW",
               refresh_token: "RT",
               scope: "files.content.read files.content.write",
               account_id: "dbid:AAA",
               uid: "329807743"
             } = token

      assert DateTime.diff(token.expires_at, DateTime.utc_now()) in 14_000..14_400
    end

    test "sends the PKCE verifier instead of the secret for public apps" do
      Req.Test.stub(Magpie, fn conn ->
        assert %{
                 "code" => "AUTH_CODE",
                 "grant_type" => "authorization_code",
                 "client_id" => "APP_KEY",
                 "code_verifier" => "VERIFIER"
               } == read_form(conn)

        Req.Test.json(conn, %{"access_token" => "sl.NEW", "expires_in" => 14_400})
      end)

      assert {:ok, %Token{access_token: "sl.NEW"}} =
               Auth.exchange_code("APP_KEY", "AUTH_CODE", code_verifier: "VERIFIER")
    end

    test "maps OAuth errors to Magpie.Error" do
      Req.Test.stub(Magpie, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "error" => "invalid_grant",
          "error_description" => "code doesn't exist or has expired"
        })
      end)

      assert {:error, error} =
               Auth.exchange_code("APP_KEY", "USED_CODE", app_secret: "APP_SECRET")

      assert %Magpie.Error{
               status: 400,
               summary: "invalid_grant",
               body: %{"error_description" => "code doesn't exist or has expired"}
             } = error

      assert Exception.message(error) == "Dropbox returned status 400: invalid_grant"
    end
  end

  describe "refresh/3" do
    test "trades the refresh token for a new access token" do
      Req.Test.stub(Magpie, fn conn ->
        assert conn.request_path == "/oauth2/token"

        assert %{
                 "refresh_token" => "RT",
                 "grant_type" => "refresh_token",
                 "client_id" => "APP_KEY",
                 "client_secret" => "APP_SECRET"
               } == read_form(conn)

        Req.Test.json(conn, %{
          "access_token" => "sl.FRESH",
          "expires_in" => 14_400,
          "token_type" => "bearer"
        })
      end)

      assert {:ok, token} = Auth.refresh("APP_KEY", "RT", app_secret: "APP_SECRET")

      # Dropbox does not rotate refresh tokens — the caller keeps the original
      assert %Token{access_token: "sl.FRESH", refresh_token: nil, account_id: nil} = token
      assert DateTime.diff(token.expires_at, DateTime.utc_now()) > 14_000
    end

    test "omits the client secret for PKCE apps" do
      Req.Test.stub(Magpie, fn conn ->
        assert %{
                 "refresh_token" => "RT",
                 "grant_type" => "refresh_token",
                 "client_id" => "APP_KEY"
               } == read_form(conn)

        Req.Test.json(conn, %{"access_token" => "sl.FRESH", "expires_in" => 14_400})
      end)

      assert {:ok, %Token{access_token: "sl.FRESH"}} = Auth.refresh("APP_KEY", "RT")
    end

    test "maps a revoked refresh token to Magpie.Error" do
      Req.Test.stub(Magpie, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "invalid_grant", "error_description" => "refresh token"})
      end)

      assert {:error, %Magpie.Error{status: 400, summary: "invalid_grant"}} =
               Auth.refresh("APP_KEY", "REVOKED", app_secret: "APP_SECRET")
    end

    test "leaves the expiry unknown when Dropbox omits expires_in" do
      Req.Test.stub(Magpie, fn conn ->
        Req.Test.json(conn, %{"access_token" => "sl.FRESH", "token_type" => "bearer"})
      end)

      assert {:ok, %Token{access_token: "sl.FRESH", expires_at: nil}} =
               Auth.refresh("APP_KEY", "RT", app_secret: "APP_SECRET")
    end

    test "handles token endpoint errors that are not JSON" do
      Req.Test.stub(Magpie, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Plug.Conn.send_resp(503, "service unavailable")
      end)

      assert {:error, %Magpie.Error{status: 503, summary: nil, body: "service unavailable"}} =
               Auth.refresh("APP_KEY", "RT", app_secret: "APP_SECRET")
    end
  end

  defp read_form(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    URI.decode_query(body)
  end
end
