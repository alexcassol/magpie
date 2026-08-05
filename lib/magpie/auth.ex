defmodule Magpie.Auth do
  @moduledoc """
  OAuth 2 flow helpers — plus the endpoints of the Dropbox `auth` namespace.

  Dropbox no longer issues long-lived access tokens: they expire after about
  four hours, so any application that runs longer than that must use the
  refresh token flow. The functions here are stateless — they build the
  authorization URL and talk to Dropbox's `/oauth2/token` endpoint. Keeping
  a token fresh over time is `Magpie.Auth.TokenServer`'s job.

  The whole flow, end to end:

      # 1. Send the user to Dropbox
      {verifier, challenge} = Magpie.Auth.pkce_pair()

      url =
        Magpie.Auth.authorize_url(app_key,
          redirect_uri: "https://myapp.com/dropbox/callback",
          state: csrf_token,
          scope: ["account_info.read", "files.content.write"],
          code_challenge: challenge
        )

      # 2. Dropbox redirects back with ?code=...
      {:ok, token} =
        Magpie.Auth.exchange_code(app_key, code,
          code_verifier: verifier,
          redirect_uri: "https://myapp.com/dropbox/callback"
        )

      # 3. Store token.refresh_token, then build clients from it
      client = Magpie.Client.new(refresh_token: token.refresh_token, app_key: app_key, pkce: true)

  See the [OAuth guide](oauth.html) for the full walkthrough, including how
  to get a refresh token without writing any code.

  ## Endpoints

  The OAuth endpoints can be overridden (rarely needed) via:

      config :magpie,
        oauth_authorize_url: "https://www.dropbox.com/oauth2/authorize",
        oauth_token_url: "https://api.dropboxapi.com/oauth2/token"

  """
  import Magpie

  alias Magpie.Auth.Token
  alias Magpie.Error

  # PKCE verifiers must be 43-128 characters long (RFC 7636, section 4.1).
  # 64 random bytes encode to 86 unreserved characters.
  @verifier_bytes 64

  @http_timeout 15_000

  @type token_opt ::
          {:app_secret, String.t() | nil}
          | {:code_verifier, String.t() | nil}
          | {:redirect_uri, String.t() | nil}

  @doc """
  Builds the URL where the user authorizes your app.

  `token_access_type` defaults to `"offline"`, which is what makes Dropbox
  return a refresh token alongside the access token.

  ## Options

    * `:redirect_uri` — where Dropbox sends the user back to. Must match one
      of the redirect URIs registered in the App Console
    * `:state` — opaque value echoed back in the redirect, used to protect
      against CSRF (and to carry your own context)
    * `:scope` — list of scopes (or an already space-separated string). When
      omitted, the app's configured scopes are granted
    * `:code_challenge` — PKCE challenge from `pkce_pair/0`; adds
      `code_challenge_method=S256`
    * `:token_access_type` — `"offline"` (default), `"online"` or `"legacy"`
    * `:extra_params` — keyword list or map of additional Dropbox
      authorization params (`force_reapprove`, `locale`, `require_role`,
      `disable_signup`, ...), appended after the standard ones. Values are
      rendered with `to_string/1`, so booleans and atoms work. Params this
      function already sets cannot be overridden — a collision raises
      `ArgumentError`

  ## Examples

      iex> Magpie.Auth.authorize_url("APP_KEY")
      "https://www.dropbox.com/oauth2/authorize?client_id=APP_KEY&response_type=code&token_access_type=offline"

      iex> Magpie.Auth.authorize_url("APP_KEY",
      ...>   redirect_uri: "https://myapp.com/cb",
      ...>   scope: ["files.content.read", "files.content.write"]
      ...> )
      "https://www.dropbox.com/oauth2/authorize?client_id=APP_KEY&response_type=code&token_access_type=offline&redirect_uri=https%3A%2F%2Fmyapp.com%2Fcb&scope=files.content.read%20files.content.write"

      iex> Magpie.Auth.authorize_url("APP_KEY",
      ...>   extra_params: [force_reapprove: true, locale: "pt_BR"]
      ...> )
      "https://www.dropbox.com/oauth2/authorize?client_id=APP_KEY&response_type=code&token_access_type=offline&force_reapprove=true&locale=pt_BR"

  """
  @spec authorize_url(String.t(), keyword()) :: String.t()
  def authorize_url(app_key, opts \\ []) do
    params =
      [
        client_id: app_key,
        response_type: "code",
        token_access_type: Keyword.get(opts, :token_access_type, "offline")
      ]
      |> put_param(:redirect_uri, opts[:redirect_uri])
      |> put_param(:state, opts[:state])
      |> put_param(:scope, scope_param(opts[:scope]))
      |> put_challenge(opts[:code_challenge])
      |> put_extra_params(opts[:extra_params])

    oauth_authorize_url() <> "?" <> URI.encode_query(params, :rfc3986)
  end

  @doc """
  Generates a PKCE `{code_verifier, code_challenge}` pair.

  Public apps (mobile, desktop, CLIs — anything that cannot keep a secret)
  use PKCE instead of the app secret: send the challenge to
  `authorize_url/2` and the verifier to `exchange_code/3`.

      iex> {verifier, challenge} = Magpie.Auth.pkce_pair()
      iex> byte_size(verifier)
      86
      iex> challenge == Magpie.Auth.pkce_challenge(verifier)
      true

  """
  @spec pkce_pair() :: {verifier :: String.t(), challenge :: String.t()}
  def pkce_pair do
    verifier = @verifier_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    {verifier, pkce_challenge(verifier)}
  end

  @doc """
  Derives the S256 PKCE challenge of a verifier.

  Test vector from [RFC 7636, appendix B](https://datatracker.ietf.org/doc/html/rfc7636#appendix-B):

      iex> Magpie.Auth.pkce_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
      "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

  """
  @spec pkce_challenge(String.t()) :: String.t()
  def pkce_challenge(verifier) when is_binary(verifier) do
    :sha256
    |> :crypto.hash(verifier)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Exchanges the authorization code Dropbox sent to your redirect URI for a
  token set.

  Pass `:app_secret` for confidential apps, or `:code_verifier` for PKCE
  apps. `:redirect_uri` is required whenever it was present in the
  authorization request, and must be identical.

  This is the only response that carries a `refresh_token` — store it.

      {:ok, %Magpie.Auth.Token{refresh_token: refresh_token}} =
        Magpie.Auth.exchange_code(app_key, code,
          app_secret: app_secret,
          redirect_uri: "https://myapp.com/dropbox/callback"
        )

  Returns `{:error, %Magpie.Error{}}` when Dropbox rejects the exchange —
  `summary` then holds the OAuth error code (e.g. `"invalid_grant"` for an
  expired or already-used code).
  """
  @spec exchange_code(String.t(), String.t(), [token_opt()]) ::
          {:ok, Token.t()} | {:error, Error.t()}
  def exchange_code(app_key, code, opts \\ []) do
    [code: code, grant_type: "authorization_code", client_id: app_key]
    |> put_param(:client_secret, opts[:app_secret])
    |> put_param(:code_verifier, opts[:code_verifier])
    |> put_param(:redirect_uri, opts[:redirect_uri])
    |> token_request()
  end

  @doc """
  Trades a refresh token for a fresh access token.

  Pass `:app_secret` for confidential apps; PKCE apps authenticate with the
  app key alone. Dropbox does not rotate refresh tokens, so the response
  carries no `refresh_token` — keep using the one you already have.

      {:ok, %Magpie.Auth.Token{access_token: access_token, expires_at: expires_at}} =
        Magpie.Auth.refresh(app_key, refresh_token, app_secret: app_secret)

  Returns `{:error, %Magpie.Error{}}` when the refresh token was revoked or
  is invalid (`summary: "invalid_grant"`).
  """
  @spec refresh(String.t(), String.t(), [token_opt()]) :: {:ok, Token.t()} | {:error, Error.t()}
  def refresh(app_key, refresh_token, opts \\ []) do
    [refresh_token: refresh_token, grant_type: "refresh_token", client_id: app_key]
    |> put_param(:client_secret, opts[:app_secret])
    |> token_request()
  end

  @doc """
  Disables the access token used to authenticate the call.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#auth-token-revoke
  """
  def token_revoke(client) do
    post(client, "/auth/token/revoke")
  end

  defp token_request(form) do
    # Bounded on purpose: a token request often runs inside
    # `Magpie.Auth.TokenServer`, where a hanging call would block every
    # other caller waiting for the same refresh.
    [
      url: oauth_token_url(),
      form: form,
      connect_options: [timeout: @http_timeout],
      receive_timeout: @http_timeout
    ]
    |> Keyword.merge(Application.get_env(:magpie, :req_options, []))
    |> Req.new()
    |> Req.post!()
    |> token_response()
  end

  defp token_response(%Req.Response{status: 200, body: body}) when is_map(body),
    do: {:ok, Token.from_response(body)}

  defp token_response(%Req.Response{status: status, body: body}),
    do: {:error, Error.new(status, body)}

  defp put_param(params, _key, nil), do: params
  defp put_param(params, key, value), do: params ++ [{key, value}]

  defp put_extra_params(params, nil), do: params

  defp put_extra_params(params, extra) when is_list(extra) or is_map(extra) do
    # Extra params may only add — overriding a param this module builds
    # (client_id, response_type, token_access_type, code_challenge, ...)
    # would silently change the security properties of the flow.
    taken = MapSet.new(params, fn {key, _value} -> to_string(key) end)

    Enum.reduce(extra, params, fn {key, value}, acc ->
      if MapSet.member?(taken, to_string(key)) do
        raise ArgumentError,
              "extra_params cannot override the #{inspect(to_string(key))} param — " <>
                "it is set by authorize_url/2 itself"
      end

      acc ++ [{key, value}]
    end)
  end

  defp put_challenge(params, nil), do: params

  defp put_challenge(params, challenge),
    do: params ++ [code_challenge: challenge, code_challenge_method: "S256"]

  defp scope_param(nil), do: nil
  defp scope_param(scope) when is_binary(scope), do: scope
  defp scope_param(scopes) when is_list(scopes), do: Enum.join(scopes, " ")
end
