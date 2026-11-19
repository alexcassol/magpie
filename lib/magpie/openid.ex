defmodule Magpie.OpenId do
  @moduledoc """
  Endpoints of the Dropbox `openid` namespace.
  """
  import Magpie

  @doc """
  Returns the OpenID user info for the current user. Requires the token to
  have been obtained with the `openid` scope.

  Identify the user by `"sub"` (their Dropbox `account_id`), never by
  `"email"`: an email can change and be reused by another account.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#openid-userinfo
  """
  def userinfo(client) do
    post(client, "/openid/userinfo", %{})
  end
end
