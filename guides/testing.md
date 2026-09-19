# Testing integrations

## Testing your application

Add `:plug` to your test dependencies and configure a client with `Req.Test`.
Each test can then use its own stub without changing application settings.

```elixir
defmodule MyApp.DropboxTest do
  use ExUnit.Case, async: true

  test "reports an API error on a continuation page" do
    client = Magpie.Client.new("fake-token",
      req_options: [plug: {Req.Test, __MODULE__}], retry: false)

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/2/files/list_folder" ->
          Req.Test.json(conn, %{
            "entries" => [%{".tag" => "file", "name" => "first.txt"}],
            "cursor" => "next-page", "has_more" => true
          })

        "/2/files/list_folder/continue" ->
          conn
          |> Plug.Conn.put_status(409)
          |> Req.Test.json(%{"error_summary" => "reset/.."})
      end
    end)

    assert {:error, %Magpie.Error{endpoint: "/files/list_folder/continue"}} =
      Magpie.Storage.list(client, "/Backup")
  end
end
```

Use `Req.Test.transport_error(conn, :timeout)` to simulate a transport failure.
Test failures on both the first page and a continuation page; they take different
paths through the library. For upload sessions, stub `start`, `append_v2` and
`finish`, then check that a failed append prevents the commit.

The repository has more examples in `test/flows_test.exs`,
`test/reliability_test.exs` and `test/configuration_test.exs`.

For a supervised token server that runs outside the test process, configure its
own `req_options: [plug: {Req.Test, stub_name}]` and grant access with
`Req.Test.allow(stub_name, self(), server_pid)`. Use fake tokens in fixtures.

## Running the suite

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix docs --warnings-as-errors
```

The default suite needs no Dropbox account. Most tests use `Req.Test`;
`test/http_integration_test.exs` runs a local TCP server to test retries and
timeouts through Req/Finch. CI runs tests on Elixir/OTP 1.15.8/26.2,
1.18.4/27.3 and 1.20/29. Formatting and coverage use the newest combination.

## Testing against Dropbox

Use a **dedicated test account and app** with `files.metadata.read`,
`files.content.read` and `files.content.write` granted. Provide a valid token via
`MAGPIE_TEST_DROPBOX_TOKEN`, then run:

```sh
mix test test/dropbox_integration_test.exs --include dropbox
```

This test runs only with `--include dropbox`. It creates a unique
`/magpie-integration-*` folder, checks uploads, revision conflicts, downloads and
pagination, then deletes that folder. Failed cleanup fails the test. If you kill
the test process, you may need to remove the folder yourself.

The test does not try to trigger rate limits. Normal CI runs without Dropbox
credentials.
