defmodule Magpie.Users do
  @moduledoc """
  This namespace contains endpoints and data types for user management.
  """
  alias Magpie.Client
  import Magpie
  import Magpie.Utils

  @doc """
  Get user account by account_id.

  ## Example

    Magpie.Users.get_account client, "dbid:..."

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#users-get_account
  """
  @spec get_account(Client.t(), binary) :: Magpie.response()
  def get_account(client, id) do
    body = %{"account_id" => id}
    post(client, "/users/get_account", body)
  end

  @doc """
  Same as `get_account/2` but returns `{:ok, %Magpie.Account{}}`.
  """
  @spec get_account_to_struct(Client.t(), binary) ::
          {:ok, Magpie.Account.t()} | {:error, Magpie.Error.t()}
  def get_account_to_struct(client, id) do
    case get_account(client, id) do
      {:ok, response} -> {:ok, to_struct(%Magpie.Account{}, response)}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Get the current user's account.

  ## Example

    Magpie.Users.current_account client

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#users-get_current_account
  """
  @spec current_account(Client.t()) :: Magpie.response()
  def current_account(client) do
    post(client, "/users/get_current_account")
  end

  @doc """
  Same as `current_account/1` but returns `{:ok, %Magpie.Account{}}`.
  """
  @spec current_account_to_struct(Client.t()) ::
          {:ok, Magpie.Account.t()} | {:error, Magpie.Error.t()}
  def current_account_to_struct(client) do
    case current_account(client) do
      {:ok, response} -> {:ok, to_struct(%Magpie.Account{}, response)}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Get the current user's space usage.

  ## Example

    Magpie.Users.get_space_usage client

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#users-get_space_usage
  """
  @spec get_space_usage(Client.t()) :: Magpie.response()
  def get_space_usage(client) do
    post(client, "/users/get_space_usage")
  end

  @doc """
  Same as `get_space_usage/1` but returns `{:ok, %Magpie.SpaceUsage{}}`.
  """
  @spec get_space_usage_to_struct(Client.t()) ::
          {:ok, Magpie.SpaceUsage.t()} | {:error, Magpie.Error.t()}
  def get_space_usage_to_struct(client) do
    case get_space_usage(client) do
      {:ok, response} -> {:ok, to_struct(%Magpie.SpaceUsage{}, response)}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Get user accounts in batch by their account ids.

  ## Example

    Magpie.Users.get_account_batch client, ["dbid:1", "dbid:2"]

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#users-get_account_batch
  """
  @spec get_account_batch(Client.t(), [binary]) :: Magpie.response()
  def get_account_batch(client, account_ids) do
    body = %{"account_ids" => account_ids}
    post(client, "/users/get_account_batch", body)
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
