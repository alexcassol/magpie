defmodule Magpie.Files.Locks do
  @moduledoc """
  File locking endpoints (`/files/*_file_lock_batch`), useful to coordinate
  editing on shared files.

  Each entry is a map with the file `"path"`.
  """
  import Magpie

  @doc """
  Lock the files at the given paths.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-lock_file_batch
  """
  def lock_file_batch(client, entries) do
    post(client, "/files/lock_file_batch", %{"entries" => entries})
  end

  @doc """
  Unlock the files at the given paths.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-unlock_file_batch
  """
  def unlock_file_batch(client, entries) do
    post(client, "/files/unlock_file_batch", %{"entries" => entries})
  end

  @doc """
  Return the lock metadata for the given list of paths.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-get_file_lock_batch
  """
  def get_file_lock_batch(client, entries) do
    post(client, "/files/get_file_lock_batch", %{"entries" => entries})
  end
end
