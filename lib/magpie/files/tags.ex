defmodule Magpie.Files.Tags do
  @moduledoc """
  User-defined tags on files (`/files/tags/*`).
  """
  import Magpie

  @doc """
  Add a tag to an item.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-tags-add
  """
  def add(client, path, tag_text) do
    post(client, "/files/tags/add", %{"path" => path, "tag_text" => tag_text})
  end

  @doc """
  Get the tags of one or more items.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-tags-get
  """
  def get(client, paths) do
    post(client, "/files/tags/get", %{"paths" => paths})
  end

  @doc """
  Remove a tag from an item.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-tags-remove
  """
  def remove(client, path, tag_text) do
    post(client, "/files/tags/remove", %{"path" => path, "tag_text" => tag_text})
  end
end
