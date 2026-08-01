defmodule Magpie.Files.UploadSession do
  @moduledoc """
  This namespace contains endpoints and data types for basic file operations.
  """
  import Magpie

  @doc """
  Upload sessions allow you to upload a single file in one or more requests,
  for example where the size of the file is greater than 150 MB.

  ## Example

    Magpie.Files.UploadSession.start(client, false, "/Tmp")

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-upload_session-start
  """
  def start(client, close, file) do
    dropbox_headers = %{
      :close => close
    }

    headers = %{
      "Dropbox-API-Arg" => Jason.encode!(dropbox_headers),
      "Content-Type" => "application/octet-stream"
    }

    upload_request(
      client,
      upload_url(),
      "files/upload_session/start",
      file,
      headers
    )
  end

  @doc """
  Append more data to an upload session.

  ## Example

    Magpie.Files.UploadSession.append(client, "AAAAAAAADipnX-8-d8-V4g", false, "")

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-upload_session-append_v2
  """
  def append(client, session_id, close, file, offset \\ 0) do
    cursor = %{"session_id" => session_id, "offset" => offset}

    dropbox_headers = %{
      :close => close,
      :cursor => cursor
    }

    headers = %{
      "Dropbox-API-Arg" => Jason.encode!(dropbox_headers),
      "Content-Type" => "application/octet-stream"
    }

    upload_request(
      client,
      upload_url(),
      "files/upload_session/append_v2",
      file,
      headers
    )
  end

  @doc """
  Finish an upload session and save the uploaded data to the given file path.

  ## Example

    Magpie.Files.UploadSession.finish(client, "AAAAAAAADipnX-8-d8-V4g", "", "")

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-upload_session-finish
  """
  def finish(
        client,
        session_id,
        path,
        file,
        offset \\ 0,
        mode \\ "add",
        autorename \\ true,
        mute \\ false
      ) do
    cursor = %{"session_id" => session_id, "offset" => offset}
    commit = %{"path" => path, "mode" => mode, "autorename" => autorename, "mute" => mute}

    dropbox_headers = %{
      :cursor => cursor,
      :commit => commit
    }

    headers = %{
      "Dropbox-API-Arg" => Jason.encode!(dropbox_headers),
      "Content-Type" => "application/octet-stream"
    }

    upload_request(
      client,
      upload_url(),
      "files/upload_session/finish",
      file,
      headers
    )
  end

  @doc """
  This route helps you commit many files at once into a user's Dropbox.

  ## Example
    entry = %{ "cursor" => %{ "session_id" => "AAAAAAAADipnX-8-d8-V4g", "offset" => 0}, "commit" => %{ "path" => "/Homework/math/Matrices.txt" }}
    entries = [entry]
    Magpie.Files.UploadSession.finish_batch client, entries

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-upload_session-finish_batch_v2
  """
  def finish_batch(client, entries) do
    body = %{"entries" => entries}
    post(client, "/files/upload_session/finish_batch_v2", body)
  end

  @doc """
  Start multiple upload sessions at once. `opts` accepts `"session_type"`
  (`%{".tag" => "sequential"}` or `%{".tag" => "concurrent"}`).

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-upload_session-start_batch
  """
  def start_batch(client, num_sessions, opts \\ %{}) do
    body = Map.merge(%{"num_sessions" => num_sessions}, opts)
    post(client, "/files/upload_session/start_batch", body)
  end

  @doc """
  Append data to multiple upload sessions in a single request. `data` is the
  concatenated content for all sessions (iodata), split according to each
  entry's `"length"`; entries are maps with `"cursor"`, `"length"` and
  optionally `"close"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-upload_session-append_batch
  """
  def append_batch(client, entries, data) do
    arg = %{"entries" => entries}

    headers = %{
      "Dropbox-API-Arg" => Jason.encode!(arg),
      "Content-Type" => "application/octet-stream"
    }

    upload_data_request(client, upload_url(), "files/upload_session/append_batch", data, headers)
  end

  @doc """
  Returns the status of an asynchronous job for
  upload_session/finish_batch.
  If success, it returns list of result for each entry.

  ## Example

    Magpie.Files.UploadSession.finish_batch_check(client, "")

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-upload_session-finish_batch-check
  """
  def finish_batch_check(client, async_job_id) do
    body = %{"async_job_id" => async_job_id}
    post(client, "/files/upload_session/finish_batch/check", body)
  end
end
