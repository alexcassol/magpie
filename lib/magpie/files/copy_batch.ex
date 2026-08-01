defmodule Magpie.Files.CopyBatch do
  @moduledoc """
  Batch copy operations (`/files/copy_batch_v2`).
  """
  import Magpie

  @doc """
  Copy multiple files or folders to different locations at once in the user's Dropbox.

  ## Example

    Magpie.Files.CopyBatch.copy_batch(client, "/Temp/", "/Tmp")

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-copy_batch_v2
  """
  def copy_batch(client, from_path, to_path, autorename \\ false) do
    body = %{
      "entries" => [%{"from_path" => from_path, "to_path" => to_path}],
      "autorename" => autorename
    }

    post(client, "/files/copy_batch_v2", body)
  end

  @doc """
  Returns the status of an asynchronous job for `copy_batch/4`.

  ## Example

    Magpie.Files.CopyBatch.check(client, "")

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-copy_batch-check_v2
  """
  def check(client, async_job_id) do
    body = %{"async_job_id" => async_job_id}
    post(client, "/files/copy_batch/check_v2", body)
  end
end
