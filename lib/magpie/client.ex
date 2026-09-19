defmodule Magpie.Client do
  @moduledoc """
  Holds the credentials used to authenticate every request.

  A client is a plain struct — build one and pass it to any Magpie
  function. There are three ways to build it:

      # 1. A static access token. Simplest, but Dropbox access tokens expire
      #    in about 4 hours — fine for scripts, not for daemons.
      client = Magpie.Client.new("ACCESS_TOKEN")

      # 2. A refresh token. Magpie starts a linked `Magpie.Auth.TokenServer`
      #    and keeps the access token fresh for you.
      client = Magpie.Client.new(refresh_token: rt, app_key: key, app_secret: secret)
      client = Magpie.Client.new(refresh_token: rt, app_key: key, pkce: true)

      # 3. A token provider you supervise (or wrote) yourself.
      client = Magpie.Client.new(token_provider: {Magpie.Auth.TokenServer, MyApp.DropboxToken})
      client = Magpie.Client.new(token_provider: {MyApp.DropboxTokens, "user-42"})

  Form 2 links the token server to the calling process, which is convenient
  in scripts and `iex`, but in an application you usually want the server in
  your supervision tree — see `Magpie.Auth.TokenServer` and the
  [OAuth guide](oauth.html).

  Whatever the form, the credentials end up behind a
  `Magpie.Auth.TokenProvider` stored in `token_provider`.
  """

  alias Magpie.Auth.StaticToken
  alias Magpie.Auth.TokenServer

  @derive {Inspect, only: []}
  defstruct access_token: nil, token_provider: nil, config: [], deadline: nil

  @type provider :: {module(), term()}
  @type access_token :: binary()
  @type t :: %__MODULE__{
          access_token: access_token | nil,
          token_provider: provider | nil,
          config: keyword(),
          deadline: integer() | nil
        }
  @type m :: %__MODULE__{}

  @doc """
  Builds a client with no credentials.

      iex> Magpie.Client.new()
      %Magpie.Client{access_token: nil, token_provider: nil}

  """
  @spec new() :: m
  def new(), do: %__MODULE__{}

  @doc """
  Builds a client from an access token, a refresh token or a token provider.

  ## Examples

      iex> client = Magpie.Client.new("ACCESS_TOKEN")
      iex> client.token_provider
      {Magpie.Auth.StaticToken, "ACCESS_TOKEN"}

      iex> client = Magpie.Client.new(token_provider: {Magpie.Auth.TokenServer, MyApp.DropboxToken})
      iex> client.token_provider
      {Magpie.Auth.TokenServer, MyApp.DropboxToken}

  With `:refresh_token`, a `Magpie.Auth.TokenServer` is started and linked to
  the calling process. Token options (`:name`, `:refresh_margin`, `:on_refresh`,
  ...) are forwarded to it; `:oauth_req_options` configures its HTTP calls
  separately from the client's file-request `:req_options`:

      client =
        Magpie.Client.new(
          refresh_token: System.fetch_env!("DROPBOX_REFRESH_TOKEN"),
          app_key: System.fetch_env!("DROPBOX_APP_KEY"),
          app_secret: System.fetch_env!("DROPBOX_APP_SECRET")
        )

  """
  @spec new(access_token | keyword()) :: t
  def new(access_token) when is_binary(access_token) do
    %__MODULE__{access_token: access_token, token_provider: {StaticToken, access_token}}
  end

  def new(opts) when is_list(opts) do
    Magpie.Options.keyword!(opts)
    {config, credentials} = Keyword.split(opts, Magpie.Options.config_keys())
    Magpie.Options.config!(config)

    allowed = [
      :token_provider,
      :refresh_token,
      :access_token,
      :app_key,
      :app_secret,
      :pkce,
      :name,
      :refresh_margin,
      :on_refresh,
      :expires_at,
      :oauth_req_options
    ]

    if Enum.any?(Keyword.keys(credentials), &(&1 not in allowed)),
      do: raise(ArgumentError, "unsupported client option")

    client =
      cond do
        provider = credentials[:token_provider] ->
          %__MODULE__{token_provider: provider!(provider)}

        credentials[:refresh_token] ->
          %__MODULE__{token_provider: start_token_server!(credentials)}

        is_binary(credentials[:access_token]) ->
          new(credentials[:access_token])

        true ->
          raise ArgumentError,
                "expected a :token_provider or a :refresh_token option, or :access_token"
      end

    %{client | config: config}
  end

  @doc "Builds a static-token client with its own request settings."
  @spec new(binary(), keyword()) :: t()
  def new(token, opts) when is_binary(token), do: with_options(new(token), opts)

  @doc """
  Returns a client with merged configuration; the original is unchanged.

  Supports `:req_options`, `:retry` (false or a keyword list), `:timeout`
  (execution budget in milliseconds or `:infinity`), `:base_url`,
  `:upload_url`, `:account_id` (a local diagnostic label), and `:scopes`
  (a list of known granted scopes, or nil when unknown).

  Precedence is operation > client > application > defaults. `:req_options`
  merge by key; `:retry` replaces the entire policy. Request configuration
  does not reconfigure an independently supervised OAuth token provider.
  See the [configuration guide](configuration.html) for budget semantics.
  """
  @spec with_options(t(), keyword()) :: t()
  def with_options(%__MODULE__{} = client, opts) do
    Magpie.Options.config!(opts)

    config =
      Keyword.merge(client.config, opts, fn
        :req_options, old, new -> Keyword.merge(old, new)
        _key, _old, new -> new
      end)

    %{client | config: config}
  end

  @doc """
  Lists missing scopes from caller-supplied grants, or returns `:unknown`.

  Uses the scope list supplied by the caller. It does not contact Dropbox
  or block requests.
  """
  @spec missing_scopes(t(), [String.t()]) :: [String.t()] | :unknown
  def missing_scopes(client, required) when is_list(required) do
    case Keyword.get(client.config, :scopes) do
      nil -> :unknown
      granted -> required -- granted
    end
  end

  @doc false
  def option(client, key, default \\ nil) do
    Keyword.get(Map.get(client, :config, []), key, Application.get_env(:magpie, key, default))
  end

  @doc false
  def begin_operation(client) do
    timeout = option(client, :timeout, :infinity)
    Magpie.Options.config!(timeout: timeout)
    %{client | deadline: client.deadline || Magpie.Budget.deadline(timeout)}
  end

  @doc """
  Returns the `{module, arg}` token provider a client authenticates with.

  Clients built by hand (`%Magpie.Client{access_token: "..."}`) fall back to
  `Magpie.Auth.StaticToken`.

      iex> Magpie.Client.token_provider(%Magpie.Client{access_token: "ACCESS_TOKEN"})
      {Magpie.Auth.StaticToken, "ACCESS_TOKEN"}

  """
  @spec token_provider(struct()) :: provider
  def token_provider(client) do
    case Map.get(client, :token_provider) do
      {module, _arg} = provider when is_atom(module) -> provider
      nil -> {StaticToken, Map.get(client, :access_token)}
    end
  end

  defp provider!({module, _arg} = provider) when is_atom(module), do: provider

  defp provider!(_other) do
    raise ArgumentError,
          "expected :token_provider to be a {module, arg} tuple"
  end

  defp start_token_server!(opts) do
    {oauth_options, opts} = Keyword.pop(opts, :oauth_req_options, [])
    opts = Keyword.put(opts, :req_options, oauth_options)

    case TokenServer.start_link(opts) do
      {:ok, pid} -> {TokenServer, pid}
      {:error, {:already_started, pid}} -> {TokenServer, pid}
      {:error, _reason} -> raise "could not start Magpie.Auth.TokenServer"
    end
  end
end
