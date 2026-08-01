defmodule Magpie.Async do
  @moduledoc """
  Waits for Dropbox asynchronous jobs to complete.

  Batch endpoints (`copy_batch`, `move_batch`, `delete_batch`,
  `create_folder_batch`, `share_folder`, ...) may return
  `%{".tag" => "async_job_id", "async_job_id" => id}` instead of a final
  result, expecting you to poll the matching `check` endpoint until the job
  leaves the `"in_progress"` state. `await/4` runs that loop with
  exponential backoff:

      {:ok, launch} = Magpie.Files.MoveBatch.move_batch(client, entries)
      {:ok, result} = Magpie.Async.await(client, launch, &Magpie.Files.MoveBatch.check/2)

  `await/4` also accepts the job id directly, and passes through launches
  that completed synchronously (`%{".tag" => "complete"}`), so it can be
  piped unconditionally after any batch call.
  """

  @default_opts [interval: 500, max_interval: 5_000, timeout: 60_000]

  @doc """
  Polls `check_fun` until the job completes, fails, or `:timeout` elapses.

    * `launch_or_id` — the result map of a batch call (`%{".tag" => ...}`)
      or an `async_job_id` string
    * `check_fun` — two-arity function `(client, async_job_id)` hitting the
      job's check endpoint, e.g. `&Magpie.Files.MoveBatch.check/2`
    * `opts`:
      * `:interval` — initial poll interval in ms (default `500`)
      * `:max_interval` — backoff cap in ms (default `5_000`); each poll
        doubles the interval up to this value
      * `:timeout` — overall deadline in ms (default `60_000`)

  Returns `{:ok, result}` when the job reports `"complete"`,
  `{:error, :timeout}` on deadline, or the job's error/failed response
  as-is.
  """
  def await(client, launch_or_id, check_fun, opts \\ [])

  def await(_client, %{".tag" => "complete"} = result, _check_fun, _opts), do: {:ok, result}

  def await(client, %{".tag" => "async_job_id", "async_job_id" => id}, check_fun, opts),
    do: await(client, id, check_fun, opts)

  def await(client, async_job_id, check_fun, opts)
      when is_binary(async_job_id) and is_function(check_fun, 2) do
    opts = Keyword.merge(@default_opts, opts)
    deadline = now_ms() + Keyword.fetch!(opts, :timeout)

    poll(
      client,
      async_job_id,
      check_fun,
      Keyword.fetch!(opts, :interval),
      Keyword.fetch!(opts, :max_interval),
      deadline
    )
  end

  defp poll(client, id, check_fun, interval, max_interval, deadline) do
    client
    |> check_fun.(id)
    |> handle_poll(client, id, check_fun, interval, max_interval, deadline)
  end

  defp handle_poll(
         {:ok, %{".tag" => "in_progress"}},
         client,
         id,
         check_fun,
         interval,
         max,
         deadline
       ) do
    case now_ms() + interval <= deadline do
      true ->
        Process.sleep(interval)
        poll(client, id, check_fun, min(interval * 2, max), max, deadline)

      false ->
        {:error, :timeout}
    end
  end

  defp handle_poll({:ok, %{".tag" => "complete"} = result}, _client, _id, _check, _i, _m, _d),
    do: {:ok, result}

  # "failed" tags, API error tuples, anything else: hand back untouched
  defp handle_poll(other, _client, _id, _check, _interval, _max, _deadline), do: other

  defp now_ms, do: System.monotonic_time(:millisecond)
end
