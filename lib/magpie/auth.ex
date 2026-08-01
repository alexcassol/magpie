defmodule Magpie.Auth do
  @moduledoc """
  Endpoints of the Dropbox `auth` namespace.
  """
  import Magpie

  @doc """
  Disables the access token used to authenticate the call.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#auth-token-revoke
  """
  def token_revoke(client) do
    post(client, "/auth/token/revoke")
  end
end
