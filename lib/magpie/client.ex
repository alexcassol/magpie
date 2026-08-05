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

  defstruct access_token: nil, token_provider: nil

  @type provider :: {module(), term()}
  @type access_token :: binary()
  @type t :: %__MODULE__{access_token: access_token | nil, token_provider: provider | nil}
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
  the calling process — every other option (`:name`, `:refresh_margin`,
  `:on_refresh`, ...) is forwarded to it:

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
    cond do
      provider = opts[:token_provider] -> %__MODULE__{token_provider: provider!(provider)}
      opts[:refresh_token] -> %__MODULE__{token_provider: start_token_server!(opts)}
      true -> raise ArgumentError, "expected a :token_provider or a :refresh_token option"
    end
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

  defp provider!(other) do
    raise ArgumentError,
          "expected :token_provider to be a {module, arg} tuple, got: #{inspect(other)}"
  end

  defp start_token_server!(opts) do
    case TokenServer.start_link(opts) do
      {:ok, pid} -> {TokenServer, pid}
      {:error, {:already_started, pid}} -> {TokenServer, pid}
      {:error, reason} -> raise "could not start Magpie.Auth.TokenServer: #{inspect(reason)}"
    end
  end
end
