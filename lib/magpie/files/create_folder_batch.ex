defmodule Magpie.Files.CreateFolderBatch do
  @moduledoc """
  Batch folder creation (`/files/create_folder_batch`).
  """
  import Magpie

  @doc """
  Create multiple folders at once. `opts` accepts `"autorename"` and
  `"force_async"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-create_folder_batch
  """
  def create_folder_batch(client, paths, opts \\ %{}) do
    body = Map.merge(%{"paths" => paths}, opts)
    post(client, "/files/create_folder_batch", body)
  end

  @doc """
  Returns the status of an asynchronous job for `create_folder_batch/3`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-create_folder_batch-check
  """
  def check(client, async_job_id) do
    post(client, "/files/create_folder_batch/check", %{"async_job_id" => async_job_id})
  end
end
