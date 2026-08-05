defmodule Magpie.Auth.StaticToken do
  @moduledoc """
  `Magpie.Auth.TokenProvider` backed by a plain access token string.

  This is what `Magpie.Client.new("ACCESS_TOKEN")` uses internally, so the
  two forms below are equivalent:

      Magpie.Client.new("ACCESS_TOKEN")
      Magpie.Client.new(token_provider: {Magpie.Auth.StaticToken, "ACCESS_TOKEN"})

  There is nothing to refresh here: `refresh_token/1` hands back the very
  same token, so a Dropbox `expired_access_token` error propagates to the
  caller as a regular `Magpie.Error`. Dropbox access tokens are short-lived
  (~4 hours) — use `Magpie.Auth.TokenServer` for anything long-running.
  """

  @behaviour Magpie.Auth.TokenProvider

  @doc """
  Returns the wrapped token.

      iex> Magpie.Auth.StaticToken.fetch_token("sl.ABC")
      {:ok, "sl.ABC"}

  """
  @impl true
  def fetch_token(access_token), do: {:ok, access_token}

  @doc """
  Returns the wrapped token — a static token cannot be refreshed.

      iex> Magpie.Auth.StaticToken.refresh_token("sl.ABC")
      {:ok, "sl.ABC"}

  """
  @impl true
  def refresh_token(access_token), do: {:ok, access_token}
end
