defmodule Magpie.Users do
  @moduledoc """
  This namespace contains endpoints and data types for user management.
  """
  alias Magpie.Client
  import Magpie
  import Magpie.Utils

  @doc """
  Get user account by account_id

  ## Example

    Magpie.Users client, "TOKEN"

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#users-get_current_account
  """
  @spec get_account(Client, binary) :: any
  def get_account(client, id) do
    body = %{"account_id" => id}
    post(client, "/users/get_account", body)
  end

  def get_account_to_struct(client, id) do
    try do
      get_account(client, id)
      |> then(&to_struct(%Magpie.Account{}, &1))
    rescue
      error -> {:error, error}
    end
  end

  @doc """
  Get user current account

  ## Example

    Magpie.Users.current_account client

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#users-get_current_account
  """
  @spec current_account(Client) :: String | {:error, {integer(), String.t()}}
  def current_account(client) do
    case post(client, "/users/get_current_account") do
      {:ok, response} -> response
      {{:status_code, status_code}, body} -> {:error, {status_code, body}}
    end
  end

  def current_account_to_struct(client) do
    try do
      current_account(client)
      |> then(&to_struct(%Magpie.Account{}, &1))
    rescue
      error -> {:error, error}
    end
  end

  @doc """
  Get user space usage

  ## Example

    Magpie.Users.get_space_usage client

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#users-get_space_usage
  """
  @spec get_space_usage(Client) :: any
  def get_space_usage(client) do
    case post(client, "/users/get_space_usage") do
      {:ok, response} -> response
      {{:status_code, status_code}, body} -> {:error, {status_code, body}}
    end
  end

  def get_space_usage_to_struct(client) do
    try do
      get_space_usage(client)
      |> then(&to_struct(%Magpie.SpaceUsage{}, &1))
    rescue
      error -> {:error, error}
    end
  end

  @doc """
  Get user account batch by account_ids.List of user account identifiers

  ## Example

    Magpie.Users.get_account_batch client,  ["12345", "6789"]

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#users-get_account_batch
  """
  @spec get_account_batch(Client, binary) :: any
  def get_account_batch(client, account_ids) do
    body = %{"account_ids" => account_ids}

    case post(client, "/users/get_account_batch", body) do
      {:ok, response} -> response
      {{:status_code, status_code}, body} -> {:error, {status_code, body}}
    end
  end

  @doc """
  Get a list of feature values that may be configured for the current account,
  e.g. `[%{".tag" => "paper_as_files"}]`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#users-features-get_values
  """
  def features_get_values(client, features) do
    post(client, "/users/features/get_values", %{"features" => features})
  end
end
