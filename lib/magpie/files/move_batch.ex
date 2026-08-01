defmodule Magpie.Files.MoveBatch do
  @moduledoc """
  Batch move operations (`/files/move_batch_v2`).
  """
  import Magpie

  @doc """
  Move multiple files or folders to different locations at once.
  `entries` is a list of `%{"from_path" => ..., "to_path" => ...}` maps.
  `opts` accepts `"autorename"` and `"allow_ownership_transfer"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-move_batch_v2
  """
  def move_batch(client, entries, opts \\ %{}) do
    body = Map.merge(%{"entries" => entries}, opts)
    post(client, "/files/move_batch_v2", body)
  end

  @doc """
  Returns the status of an asynchronous job for `move_batch/3`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-move_batch-check_v2
  """
  def check(client, async_job_id) do
    post(client, "/files/move_batch/check_v2", %{"async_job_id" => async_job_id})
  end
end
