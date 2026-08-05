# OAuth 2 & token refresh

Dropbox access tokens expire about **four hours** after they are issued —
long-lived tokens have not been handed out since 2021. An application that
runs longer than an afternoon cannot rely on a token pasted into a config
file: it needs a **refresh token**, and something that trades it for a fresh
access token before the old one dies.

That "something" is `Magpie.Auth.TokenServer`, and Magpie wires it into
every request for you:

```elixir
client =
  Magpie.Client.new(
    refresh_token: System.fetch_env!("DROPBOX_REFRESH_TOKEN"),
    app_key: System.fetch_env!("DROPBOX_APP_KEY"),
    app_secret: System.fetch_env!("DROPBOX_APP_SECRET")
  )

# Still works at 3am, three weeks later
Magpie.Files.upload_file(client, "/Backup/db.dump", "priv/db.dump")
```

The rest of this guide is about getting that refresh token, and about
running the token server the way a real application should.

## The three ways to authenticate

| Form | When to use |
| --- | --- |
| `Magpie.Client.new("ACCESS_TOKEN")` | scripts and one-off `iex` sessions — the token dies in ~4h |
| `Magpie.Client.new(refresh_token: ..., app_key: ..., app_secret: ...)` | a single Dropbox account, one process per client |
| `Magpie.Client.new(token_provider: {module, arg})` | a supervised token server, or your own storage |

They all end up behind a `Magpie.Auth.TokenProvider` — the client never
holds a token itself, it asks the provider for one on every request.

## Getting a refresh token

### From the App Console, in five minutes

Good enough when your app talks to **one** Dropbox account (backups,
report drops, a company folder). No callback URL, no web flow.

1. Create an app at [dropbox.com/developers/apps](https://www.dropbox.com/developers/apps).
   Note the **App key** and **App secret**.
2. In the **Permissions** tab, tick the scopes you need
   (`files.content.write`, `files.content.read`, `account_info.read`, ...)
   and click **Submit**. Scopes granted later do not apply to tokens
   already issued — you have to authorize again.
3. Open the authorization URL in your browser:

   ```elixir
   Magpie.Auth.authorize_url("APP_KEY")
   # => "https://www.dropbox.com/oauth2/authorize?client_id=APP_KEY&response_type=code&token_access_type=offline"
   ```

   `token_access_type=offline` is the part that makes Dropbox return a
   refresh token — `authorize_url/2` sets it by default.

4. Approve the app. Dropbox shows an authorization code on screen — it is
   single-use and expires in minutes.
5. Trade it for tokens:

   ```elixir
   {:ok, token} = Magpie.Auth.exchange_code("APP_KEY", "THE_CODE", app_secret: "APP_SECRET")

   token.refresh_token
   # => "abcd..." — this one does not expire, store it as a secret
   ```

6. Put `token.refresh_token` in your app's secrets, next to the app key and
   secret. You are done — the access token in `token.access_token` can be
   thrown away, Magpie will mint new ones.

### From a web app, with a redirect

When each of your users connects their own Dropbox account, you need the
full redirect flow. Register the callback URL under **OAuth 2 → Redirect
URIs** in the App Console first — Dropbox refuses anything else.

```elixir
defmodule MyAppWeb.DropboxController do
  use MyAppWeb, :controller

  @scopes ["account_info.read", "files.content.read", "files.content.write"]

  def connect(conn, _params) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    url =
      Magpie.Auth.authorize_url(app_key(),
        redirect_uri: callback_url(),
        state: state,
        scope: @scopes
      )

    conn
    |> put_session(:dropbox_state, state)
    |> redirect(external: url)
  end

  # Dropbox sends the user back here with ?code=...&state=...
  def callback(conn, %{"code" => code, "state" => state}) do
    if state == get_session(conn, :dropbox_state) do
      case Magpie.Auth.exchange_code(app_key(), code,
             app_secret: app_secret(),
             redirect_uri: callback_url()
           ) do
        {:ok, token} ->
          {:ok, _account} = MyApp.Accounts.store_dropbox_token(conn.assigns.current_user, token)

          conn
          |> delete_session(:dropbox_state)
          |> put_flash(:info, "Dropbox connected")
          |> redirect(to: ~p"/settings")

        {:error, %Magpie.Error{} = error} ->
          conn
          |> put_flash(:error, "Dropbox refused the authorization: #{Exception.message(error)}")
          |> redirect(to: ~p"/settings")
      end
    else
      # Mismatched state — not a callback we started
      conn |> put_status(:bad_request) |> text("invalid state")
    end
  end

  # The user clicked "Cancel"
  def callback(conn, %{"error" => error}) do
    conn
    |> put_flash(:error, "Dropbox authorization failed: #{error}")
    |> redirect(to: ~p"/settings")
  end
end
```

The `state` parameter is what stops an attacker from feeding your callback
someone else's authorization code — always generate it, always compare it.

### Without an app secret (PKCE)

Desktop apps, mobile apps and CLIs cannot keep a secret: whatever you ship
can be read out of the binary. Those are *public* apps, and they prove
their identity with [PKCE](https://datatracker.ietf.org/doc/html/rfc7636)
instead — a random verifier that never leaves the device, and its SHA-256
challenge, which does.

```elixir
{verifier, challenge} = Magpie.Auth.pkce_pair()

url =
  Magpie.Auth.authorize_url(app_key,
    redirect_uri: "http://localhost:4000/dropbox/callback",
    state: state,
    code_challenge: challenge
  )

# ... user approves, you receive the code ...

{:ok, token} =
  Magpie.Auth.exchange_code(app_key, code,
    code_verifier: verifier,
    redirect_uri: "http://localhost:4000/dropbox/callback"
  )
```

Keep the verifier around until the exchange — it is the proof that the app
which redeems the code is the one that started the flow. From then on,
everything works as usual, minus the secret:

```elixir
Magpie.Client.new(refresh_token: token.refresh_token, app_key: app_key, pkce: true)
```

## Running the token server

`Magpie.Client.new(refresh_token: ...)` starts a `Magpie.Auth.TokenServer`
**linked to the calling process**. That is what you want in a script; in an
application you want it supervised, so it outlives the request or job that
happened to build the first client:

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MyApp.Repo,
      {Magpie.Auth.TokenServer,
       name: MyApp.DropboxToken,
       app_key: System.fetch_env!("DROPBOX_APP_KEY"),
       app_secret: System.fetch_env!("DROPBOX_APP_SECRET"),
       refresh_token: System.fetch_env!("DROPBOX_REFRESH_TOKEN")},
      MyAppWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end
```

Then build clients anywhere, as many as you like — they are just a struct
pointing at the server:

```elixir
defmodule MyApp.Dropbox do
  def client, do: Magpie.Client.new(token_provider: {Magpie.Auth.TokenServer, MyApp.DropboxToken})

  def backup!(path), do: Magpie.Files.upload_file(client(), "/Backup/#{Path.basename(path)}", path)
end
```

### How the refresh actually happens

* **Proactively** — `fetch_token/1` refreshes as soon as the token is
  within `:refresh_margin` seconds of expiring (default 300), so requests
  almost never meet an expired token.
* **Reactively** — if Dropbox rejects a token anyway (HTTP 401
  `expired_access_token`), Magpie refreshes and replays that request once,
  transparently. A second rejection is returned to you as a
  `Magpie.Error`.
* **Once at a time** — refreshes run inside the server, so a hundred
  concurrent requests hitting an expired token produce exactly one call to
  Dropbox; everyone else waits for it and gets the new token.
* **Without crashing** — a failed refresh (Dropbox down, refresh token
  revoked) replies `{:error, %Magpie.Error{}}` and keeps the old state. The
  next call tries again.

One limitation: a request whose body is a **stream** cannot be replayed,
because the bytes are already gone. In practice that is
`Magpie.Files.upload/6` and the upload-session chunks of
`Magpie.Files.upload_file/4`, which read straight from disk. Those requests
are never auto-retried — they rely on the proactive refresh instead, which
is why the default margin is comfortably larger than any single chunk
upload.

### Persisting the token

Dropbox does not rotate refresh tokens, so there is usually nothing to
save. If you do want to keep the current access token around — to survive
restarts without an extra refresh, or to hand it to another system — use
`:on_refresh`:

```elixir
{Magpie.Auth.TokenServer,
 name: MyApp.DropboxToken,
 app_key: app_key,
 app_secret: app_secret,
 refresh_token: refresh_token,
 refresh_margin: 600,
 on_refresh: &MyApp.Accounts.store_dropbox_token/1}
```

```elixir
defmodule MyApp.Accounts do
  def store_dropbox_token(%Magpie.Auth.Token{} = token) do
    MyApp.Repo.insert!(
      %MyApp.DropboxToken{
        access_token: token.access_token,
        refresh_token: token.refresh_token,
        expires_at: token.expires_at
      },
      on_conflict: {:replace_all_except, [:id]},
      conflict_target: :refresh_token
    )
  end
end
```

The callback runs inside the server, so keep it quick — and know that if it
raises, the error is logged and the refresh still counts.

Starting from a stored token skips the first refresh:

```elixir
stored = MyApp.Accounts.dropbox_token!()

{Magpie.Auth.TokenServer,
 name: MyApp.DropboxToken,
 app_key: app_key,
 app_secret: app_secret,
 refresh_token: stored.refresh_token,
 access_token: stored.access_token,
 expires_at: stored.expires_at}
```

Pass `access_token` and `expires_at` together — a token whose expiry is
unknown is refreshed right away, which is safe but pointless.

## Multiple accounts, or tokens in your database

One `TokenServer` holds one account. If your app connects many Dropbox
accounts, either start one server per account (a `DynamicSupervisor` and a
`Registry` work well) or implement `Magpie.Auth.TokenProvider` yourself and
let your database be the state:

```elixir
defmodule MyApp.DropboxTokens do
  @behaviour Magpie.Auth.TokenProvider

  @margin 300

  @impl true
  def fetch_token(account_id) do
    account = MyApp.Accounts.get_dropbox_account!(account_id)

    if DateTime.diff(account.expires_at, DateTime.utc_now()) > @margin do
      {:ok, account.access_token}
    else
      refresh_token(account_id)
    end
  end

  @impl true
  def refresh_token(account_id) do
    account = MyApp.Accounts.get_dropbox_account!(account_id)

    with {:ok, token} <-
           Magpie.Auth.refresh(app_key(), account.refresh_token, app_secret: app_secret()) do
      MyApp.Accounts.update_dropbox_token!(account, token)
      {:ok, token.access_token}
    end
  end
end
```

```elixir
client = Magpie.Client.new(token_provider: {MyApp.DropboxTokens, account.id})
```

Two things to keep in mind if you go this way: `fetch_token/1` runs on
every request, so it should be cheap (cache it, or read from ETS), and
nothing serializes the refresh for you — two concurrent requests can
refresh twice. Dropbox tolerates that, but a lock or a per-account
GenServer is nicer.

## Revoking

```elixir
{:ok, _} = Magpie.Auth.token_revoke(client)
```

That kills the access token *and* the refresh token behind it — the user
has to authorize the app again.

## Testing

Token requests go through the same `Req.Test` plumbing as everything else,
so they can be stubbed offline (see the "Testing your app" section of the
[Examples guide](examples.html)). Requests made from a `TokenServer` happen
in the server's process, which needs to be allowed explicitly:

```elixir
test "refreshes the access token" do
  server = start_supervised!({Magpie.Auth.TokenServer, app_key: "k", app_secret: "s", refresh_token: "rt"})
  Req.Test.allow(Magpie, self(), server)

  Req.Test.stub(Magpie, fn conn ->
    assert conn.request_path == "/oauth2/token"
    Req.Test.json(conn, %{"access_token" => "sl.FRESH", "expires_in" => 14_400})
  end)

  assert {:ok, "sl.FRESH"} = Magpie.Auth.TokenServer.fetch_token(server)
end
```
