defmodule Magpie.Files.CopyBatch do
  @moduledoc """
  """
  import Magpie

  @doc """
  Copy multiple files or folders to different locations at once in the user's Dropbox.

  ## Example

    Magpie.Files.CopyBatch.copy_batch(client, "/Temp/", "/Tmp")

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-copy_batch
  """
  def copy_batch(
        client,
        from_path,
        to_path,
        allow_shared_folder \\ false,
        autorename \\ false,
        allow_ownership_transfer \\ false
      ) do
    body = %{
      "entries" => [%{"from_path" => from_path, "to_path" => to_path}],
      "allow_shared_folder" => allow_shared_folder,
      "autorename" => autorename,
      "allow_ownership_transfer" => allow_ownership_transfer
    }

    post(client, "/files/copy_batch", body)
  end

  @doc """
  Copy multiple files or folders to different locations at once in the user's Dropbox.

  ## Example

    Magpie.Files.CopyBatch.check(client, "")

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-copy_batch
  """
  def check(client, async_job_id) do
    body = %{"async_job_id" => async_job_id}
    post(client, "/files/copy_batch/check", body)
  end
end
