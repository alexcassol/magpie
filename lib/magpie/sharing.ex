defmodule Magpie.Sharing do
  @moduledoc """
  Endpoints for creating and managing shared links and shared folders.
  """
  alias Magpie.Client
  import Magpie
  import Magpie.Utils

  @doc """
  Create a shared link with custom settings, returns a map.

  `settings` accepts the `SharedLinkSettings` fields, e.g.
  `%{"audience" => "public", "access" => "viewer"}`.

  ## Example

    Magpie.Sharing.create_shared_link client, "/Path"

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-create_shared_link_with_settings
  """
  @spec create_shared_link(Client.t(), binary, map) :: Magpie.response()
  def create_shared_link(client, path, settings \\ %{}) do
    body = %{"path" => path, "settings" => settings}
    post(client, "/sharing/create_shared_link_with_settings", body)
  end

  @doc """
  Create shared link returns SharedLink struct

  ## Example

    Magpie.Sharing.create_shared_link_to_struct client, "/Path"
  """
  @spec create_shared_link_to_struct(Client, binary) :: SharedLink | any
  def create_shared_link_to_struct(client, path) do
    case create_shared_link(client, path) do
      {:ok, response} -> to_struct(%Magpie.SharedLink{}, response)
      {{:status_code, status_code}, body} -> {:error, {status_code, body}}
    end
  end
end
