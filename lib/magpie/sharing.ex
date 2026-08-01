defmodule Magpie.Sharing do
  @moduledoc """
  """
  alias Magpie.Client
  import Magpie
  import Magpie.Utils

  @doc """
  Create shared link returns map

  ## Example

    Magpie.Sharing.create_shared_link client, "/Path"

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#sharing-create_shared_link
  """
  @spec create_shared_link(Client, binary) :: any
  def create_shared_link(client, path) do
    body = %{"path" => path, "short_url" => true}
    post(client, "/sharing/create_shared_link", body)
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
