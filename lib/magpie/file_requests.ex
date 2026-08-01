defmodule Magpie.FileRequests do
  @moduledoc """
  Endpoints for Dropbox file requests (`/file_requests/*`).
  """
  import Magpie

  @doc """
  Creates a file request for this user.

  ## Example
    deadline = %{ "deadline" => "2020-10-12T17:00:00Z" }
    Magpie.FileRequests.create client , "cool", "/Temp", deadline

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#file_requests-create
  """
  def create(client, title, destination, deadline, open \\ true) do
    body = %{
      "title" => title,
      "destination" => destination,
      "deadline" => deadline,
      "open" => open
    }

    post(client, "/file_requests/create", body)
  end

  @doc """
  Returns the specified file request.

  ## Example
    Magpie.FileRequests.get client , ""

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#file_requests-get
  """
  def get(client, id) do
    body = %{"id" => id}
    post(client, "/file_requests/get", body)
  end

  @doc """
  Returns a list of file requests owned by this user.
  For apps with the app folder permission, this
  will only return file requests with
  destinations in the app folder.

  ## Example
    Magpie.FileRequests.list client

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#file_requests-list
  """
  def list(client) do
    post(client, "/file_requests/list")
  end

  @doc """
  Update a file request.

  ## Example
    deadline = %{ "deadline" => "2020-10-12T17:00:00Z" }
    Magpie.FileRequests.create client, "", "cool", "/Temp", deadline

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#file_requests-list
  """
  def update(client, id, title, destination, deadline, open \\ true) do
    body = %{
      "id" => id,
      "title" => title,
      "destination" => destination,
      "deadline" => deadline,
      "open" => open
    }

    post(client, "/file_requests/update", body)
  end
end
