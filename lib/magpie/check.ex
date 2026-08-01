defmodule Magpie.Check do
  @moduledoc """
  Endpoints of the Dropbox `check` namespace, useful to validate credentials.
  """
  import Magpie

  @doc """
  Checks that the user access token works; Dropbox echoes `query` back.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#check-user
  """
  def user(client, query \\ "ping") do
    post(client, "/check/user", %{"query" => query})
  end

  @doc """
  Checks that the app key/secret pair is valid. This endpoint uses app
  authentication (basic auth), so it takes the credentials instead of a client.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#check-app
  """
  def app(app_key, app_secret, query \\ "ping") do
    [base_url: base_url(), auth: {:basic, "#{app_key}:#{app_secret}"}]
    |> Keyword.merge(Application.get_env(:magpie, :req_options, []))
    |> Req.new()
    |> post_request("/check/app", %{"query" => query})
  end
end
