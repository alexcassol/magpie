defmodule Magpie.Auth.TokenServer do
  @moduledoc """
  A `Magpie.Auth.TokenProvider` that keeps an access token fresh.

  Holds the current `Magpie.Auth.Token` plus the credentials needed to
  renew it, and refreshes it a few minutes before it expires — so requests
  never wait on a token that Dropbox is about to reject.

  Put it in your supervision tree and hand its name to the client:

      children = [
        {Magpie.Auth.TokenServer,
         name: MyApp.DropboxToken,
         app_key: System.fetch_env!("DROPBOX_APP_KEY"),
         app_secret: System.fetch_env!("DROPBOX_APP_SECRET"),
         refresh_token: System.fetch_env!("DROPBOX_REFRESH_TOKEN")}
      ]

      client = Magpie.Client.new(token_provider: {Magpie.Auth.TokenServer, MyApp.DropboxToken})

  The refresh token itself is optional at startup. A server started without
  one sits in an *unconfigured* state — calls return
  `{:error, %Magpie.Error{summary: "no_refresh_token"}}` until
  `set_refresh_token/3` hands it a token. That makes a plain static
  supervision tree work even on a fresh install, where the user has not
  authorized the app yet; see the [OAuth guide](oauth.html).

  ## Options

    * `:app_key` — your Dropbox app key (required)
    * `:refresh_token` — the long-lived refresh token. Optional: without it
      the server starts unconfigured, waiting for `set_refresh_token/3`
    * `:app_secret` — your app secret. Required unless `pkce: true`
    * `:pkce` — set to `true` for public apps, which authenticate with the
      app key alone and therefore have no secret
    * `:name` — registered name, so `Magpie.Client.new/1` and your
      supervision tree can refer to the server without carrying its pid
    * `:access_token` / `:expires_at` — an access token you already have,
      to avoid a refresh on the first call. Pass both or neither: a token
      without a known expiry is refreshed right away
    * `:refresh_margin` — how many seconds before expiry a token is
      considered stale (default `300`)
    * `:on_refresh` — 1-arity function called with the new
      `Magpie.Auth.Token` after every successful refresh, e.g. to persist it

  ## Concurrency

  Refreshes happen inside the server, so concurrent callers queue behind a
  single HTTP request — a burst of requests can never trigger a burst of
  refreshes. When a refresh fails the server keeps its previous state and
  replies `{:error, %Magpie.Error{}}` to the caller instead of crashing:
  a temporarily unreachable Dropbox should not take your supervision tree
  down, and the next call simply tries again.

  `set_refresh_token/3` goes through the same serialization: it runs before
  or after a refresh, never during one, so a refresh finishing around a
  re-authorization can never resurrect the old token.
  """

  use GenServer

  require Logger

  @behaviour Magpie.Auth.TokenProvider

  alias Magpie.Auth
  alias Magpie.Auth.Token

  @default_refresh_margin 300

  # Comfortably above the token request's own timeouts, so a slow refresh
  # fails on the HTTP call — with a proper error — instead of blowing up
  # the GenServer call of whoever asked for a token.
  @call_timeout 45_000

  @doc """
  Starts the server.

  See the module documentation for the supported options.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    GenServer.start_link(__MODULE__, validate!(opts), if(name, do: [name: name], else: []))
  end

  @doc """
  Returns the current access token, refreshing it first when it is expired
  or within `:refresh_margin` seconds of expiring.

      {:ok, access_token} = Magpie.Auth.TokenServer.fetch_token(MyApp.DropboxToken)

  An unconfigured server (no refresh token yet) answers with a
  pattern-matchable error instead of calling Dropbox:

      {:error, %Magpie.Error{summary: "no_refresh_token"}} =
        Magpie.Auth.TokenServer.fetch_token(MyApp.DropboxToken)

  """
  @impl Magpie.Auth.TokenProvider
  @spec fetch_token(GenServer.server()) :: {:ok, String.t()} | {:error, Magpie.Error.t()}
  def fetch_token(server), do: GenServer.call(server, :fetch_token, @call_timeout)

  @doc """
  Forces a refresh and returns the new access token.

  Magpie calls this for you when Dropbox rejects a token as expired; you
  rarely need to call it yourself.
  """
  @impl Magpie.Auth.TokenProvider
  @spec refresh_token(GenServer.server()) :: {:ok, String.t()} | {:error, Magpie.Error.t()}
  def refresh_token(server), do: GenServer.call(server, :refresh_token, @call_timeout)

  @doc """
  Returns the whole token currently held by the server, without refreshing.

  Handy for inspecting the expiry or persisting the token on shutdown.
  Returns `nil` while the server is unconfigured.
  """
  @spec token(GenServer.server()) :: Token.t() | nil
  def token(server), do: GenServer.call(server, :token, @call_timeout)

  @doc """
  Stores a (new) refresh token, configuring the server or replacing the
  token it holds — the re-authorization case.

  Any cached access token is discarded, since it belongs to the previous
  authorization. If you already hold a valid pair, seed the cache to save
  the first refresh — pass both options or neither:

    * `:access_token` — a currently valid access token
    * `:expires_at` — its absolute expiry, as a `DateTime`

  Dropbox is not contacted: the next `fetch_token/1` performs the refresh
  (or uses the seeded pair), so this is safe to call from a web request.

      # OAuth callback, right after the code exchange
      {:ok, token} = Magpie.Auth.exchange_code(app_key, code, app_secret: secret)
      :ok = Magpie.Auth.TokenServer.set_refresh_token(MyApp.DropboxToken, token.refresh_token)

      # On boot, from storage — seeded, so no refresh until it nears expiry
      :ok =
        Magpie.Auth.TokenServer.set_refresh_token(MyApp.DropboxToken, stored.refresh_token,
          access_token: stored.access_token,
          expires_at: stored.expires_at
        )

  """
  @spec set_refresh_token(GenServer.server(), String.t(), keyword()) :: :ok
  def set_refresh_token(server, refresh_token, opts \\ []) when is_binary(refresh_token) do
    GenServer.call(server, {:set_refresh_token, refresh_token, opts}, @call_timeout)
  end

  @impl GenServer
  def init(opts) do
    token =
      if refresh_token = opts[:refresh_token] do
        %Token{
          access_token: opts[:access_token],
          refresh_token: refresh_token,
          expires_at: opts[:expires_at]
        }
      end

    state = %{
      app_key: opts[:app_key],
      app_secret: opts[:app_secret],
      refresh_token: opts[:refresh_token],
      refresh_margin: Keyword.get(opts, :refresh_margin, @default_refresh_margin),
      on_refresh: opts[:on_refresh],
      token: token
    }

    {:ok, state}
  end

  # Unconfigured (no refresh token yet): a normal state on fresh installs,
  # answered locally — no HTTP, no crash, no logging.
  @impl GenServer
  def handle_call(call, _from, %{refresh_token: nil} = state)
      when call in [:fetch_token, :refresh_token] do
    {:reply, {:error, no_refresh_token_error()}, state}
  end

  def handle_call(:fetch_token, _from, state) do
    if Token.fresh?(state.token, state.refresh_margin) do
      {:reply, {:ok, state.token.access_token}, state}
    else
      do_refresh(state)
    end
  end

  def handle_call(:refresh_token, _from, state), do: do_refresh(state)

  def handle_call(:token, _from, state), do: {:reply, state.token, state}

  # Race safety comes from serialization: refreshes run inside handle_call,
  # so this clause executes strictly before or after any refresh — a refresh
  # minted with the old token can never overwrite the state written here.
  def handle_call({:set_refresh_token, refresh_token, opts}, _from, state) do
    # Seed the cache only with a complete pair — an access token with an
    # unknown expiry would be refreshed on first use anyway.
    {access_token, expires_at} =
      case {opts[:access_token], opts[:expires_at]} do
        {access_token, %DateTime{} = expires_at} when is_binary(access_token) ->
          {access_token, expires_at}

        _ ->
          {nil, nil}
      end

    token = %Token{
      access_token: access_token,
      refresh_token: refresh_token,
      expires_at: expires_at
    }

    {:reply, :ok, %{state | refresh_token: refresh_token, token: token}}
  end

  defp do_refresh(state) do
    case Auth.refresh(state.app_key, state.refresh_token, app_secret: state.app_secret) do
      {:ok, token} ->
        # Refresh responses carry no refresh token — Dropbox does not rotate
        # them — so the one we already hold stays in place.
        token = %{token | refresh_token: token.refresh_token || state.refresh_token}
        state = %{state | token: token, refresh_token: token.refresh_token}
        on_refresh(state.on_refresh, token)

        {:reply, {:ok, token.access_token}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  defp on_refresh(nil, _token), do: :ok

  defp on_refresh(fun, token) when is_function(fun, 1) do
    fun.(token)
    :ok
  rescue
    exception ->
      Logger.error(
        "Magpie.Auth.TokenServer :on_refresh callback raised: " <> Exception.message(exception)
      )

      :ok
  end

  defp no_refresh_token_error do
    %Magpie.Error{
      status: 401,
      summary: "no_refresh_token",
      body: %{
        "error" => "no_refresh_token",
        "error_description" =>
          "this TokenServer holds no refresh token yet — " <>
            "call Magpie.Auth.TokenServer.set_refresh_token/3 after completing the OAuth flow"
      }
    }
  end

  defp validate!(opts) do
    unless is_binary(opts[:app_key]) do
      raise ArgumentError,
            "Magpie.Auth.TokenServer requires a :app_key, got: #{inspect(opts[:app_key])}"
    end

    unless is_nil(opts[:refresh_token]) or is_binary(opts[:refresh_token]) do
      raise ArgumentError,
            "Magpie.Auth.TokenServer expects :refresh_token to be a string, " <>
              "got: #{inspect(opts[:refresh_token])}"
    end

    unless is_binary(opts[:app_secret]) or opts[:pkce] == true do
      raise ArgumentError,
            "Magpie.Auth.TokenServer requires an :app_secret, or pkce: true for public apps"
    end

    opts
  end
end
