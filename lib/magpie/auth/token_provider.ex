defmodule Magpie.Auth.TokenProvider do
  @moduledoc """
  Behaviour for anything that can hand an access token to `Magpie.Client`.

  A client stores a provider as a `{module, arg}` pair — the `arg` is opaque
  to Magpie and is passed back to every callback, so it can be a token
  string, a GenServer name, a keyword list, an account id, whatever your
  implementation needs:

      Magpie.Client.new(token_provider: {MyApp.DropboxTokens, "user-42"})

  Magpie ships two implementations: `Magpie.Auth.StaticToken` (used behind
  the scenes by `Magpie.Client.new("ACCESS_TOKEN")`) and
  `Magpie.Auth.TokenServer` (refreshes automatically).

  ## Example

      defmodule MyApp.DropboxTokens do
        @behaviour Magpie.Auth.TokenProvider

        @impl true
        def fetch_token(user_id) do
          {:ok, MyApp.Repo.get!(MyApp.DropboxAccount, user_id).access_token}
        end

        @impl true
        def refresh_token(user_id) do
          account = MyApp.Repo.get!(MyApp.DropboxAccount, user_id)

          with {:ok, token} <- Magpie.Auth.refresh(app_key(), account.refresh_token, app_secret: app_secret()) do
            MyApp.Accounts.store_token!(account, token)
            {:ok, token.access_token}
          end
        end
      end

  """

  @doc """
  Returns an access token believed to be currently valid.

  Called once per request, so implementations should be cheap — cache the
  token and refresh it proactively (a few minutes before expiry) instead of
  hitting Dropbox every time.
  """
  @callback fetch_token(arg :: term()) ::
              {:ok, access_token :: String.t()} | {:error, Magpie.Error.t()}

  @doc """
  Forces a refresh and returns the new access token.

  Called by Magpie when Dropbox rejects a token that `c:fetch_token/1`
  believed was valid (HTTP 401 `expired_access_token`).
  """
  @callback refresh_token(arg :: term()) ::
              {:ok, access_token :: String.t()} | {:error, Magpie.Error.t()}
end
