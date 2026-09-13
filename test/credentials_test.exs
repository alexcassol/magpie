defmodule Magpie.CredentialsTest do
  use ExUnit.Case, async: true

  alias Magpie.Auth.{StaticToken, Token, TokenServer}
  alias Magpie.Client

  test "server status hides credentials without changing the cached token" do
    server =
      start_supervised!(
        {TokenServer,
         app_key: "private-app-key",
         app_secret: "private-app-secret",
         refresh_token: "private-refresh-token",
         access_token: "private-access-token",
         expires_at: DateTime.add(DateTime.utc_now(), 3600)}
      )

    status = inspect(:sys.get_status(server), limit: :infinity)

    for secret <- [
          "private-app-key",
          "private-app-secret",
          "private-refresh-token",
          "private-access-token"
        ] do
      refute status =~ secret
    end

    assert {:ok, "private-access-token"} = TokenServer.fetch_token(server)
  end

  test "crash diagnostic fields redact messages and exception reasons" do
    status =
      TokenServer.format_status(%{
        state: %{refresh_token: "secret"},
        message: {:set_refresh_token, "secret", []},
        reason: {:error, "secret"},
        log: [{:in, "secret"}]
      })

    refute inspect(status) =~ "secret"
  end

  test "client inspection hides static tokens and arbitrary provider arguments" do
    secret = "private-access-token"

    for client <- [
          Client.new(secret),
          %Client{access_token: secret},
          Client.new(token_provider: {StaticToken, %{secret: secret}})
        ] do
      refute inspect(client) =~ secret
      refute inspect(%{client: client}, pretty: true, limit: :infinity) =~ secret
    end

    assert {:ok, ^secret} =
             Client.new(secret)
             |> Client.token_provider()
             |> then(fn {mod, arg} -> mod.fetch_token(arg) end)
  end

  test "token inspection retains diagnostic fields but hides both credentials" do
    token = %Token{
      access_token: "private-access-token",
      refresh_token: "private-refresh-token",
      scope: "files.content.read",
      expires_at: ~U[2026-09-13 12:00:00Z]
    }

    output = inspect(%{token: token}, pretty: true, limit: :infinity)
    refute output =~ token.access_token
    refute output =~ token.refresh_token
    assert output =~ token.scope
    assert output =~ "2026-09-13"
    assert token.refresh_token == "private-refresh-token"
  end

  test "invalid credential options are not echoed in exceptions" do
    secret = "private-credential"

    for call <- [
          fn -> Client.new(token_provider: [secret]) end,
          fn -> TokenServer.start_link(app_key: [secret]) end,
          fn -> TokenServer.start_link(app_key: "key", refresh_token: [secret]) end
        ] do
      error = assert_raise ArgumentError, call
      refute Exception.message(error) =~ secret
    end
  end
end
