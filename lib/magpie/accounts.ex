defmodule Magpie.Accounts do
  @moduledoc """
  Endpoints of the Dropbox `account` namespace (profile photo management).

  Named `Accounts` to avoid clashing with the `Magpie.Account` response struct.
  """
  import Magpie

  @doc """
  Sets a user's profile photo from base64-encoded image data.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#account-set_profile_photo
  """
  def set_profile_photo(client, base64_data) do
    body = %{"photo" => %{".tag" => "base64_data", "base64_data" => base64_data}}
    post(client, "/account/set_profile_photo", body)
  end

  @doc """
  Removes the user's profile photo.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#account-delete_profile_photo
  """
  def delete_profile_photo(client) do
    post(client, "/account/delete_profile_photo")
  end

  @doc """
  Downloads an account photo. `opts` accepts `"size"`, `"circle_crop"` and
  `"expect_account_photo"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#account-get_photo
  """
  def get_photo(client, dbx_account_id, opts \\ %{}) do
    arg = Map.merge(%{"dbx_account_id" => dbx_account_id}, opts)
    headers = %{"Dropbox-API-Arg" => Jason.encode!(arg)}
    download_request(client, upload_url(), "account/get_photo", [], headers)
  end
end
