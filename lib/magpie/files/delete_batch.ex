defmodule Magpie.Files.DeleteBatch do
  @moduledoc """
  """
  import Magpie

  @doc """
  Delete multiple files/folders at once.

  ## Example
    path_entries = [ %{"path" => "/Temp1"}, %{"path" => "/Temp2" } ]
    Magpie.Files.DeleteBatch.delete_batch(client, path_entries)

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-delete_batch
  """
  def delete_batch(client, path_entries) do
    body = %{"entries" => path_entries}
    post(client, "/files/delete_batch", body)
  end

  @doc """
  Returns the status of an asynchronous job for delete_batch. If success, it returns list of result for each entry.

  ## Example

    Magpie.Files.DeleteBatch.check(client, "")

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-delete_batch-check
  """
  def check(client, async_job_id) do
    body = %{"async_job_id" => async_job_id}
    post(client, "/files/delete_batch/check", body)
  end
end
