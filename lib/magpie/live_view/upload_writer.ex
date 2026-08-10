defmodule Magpie.LiveView.UploadWriter do
  @moduledoc """
  A `Phoenix.LiveView.UploadWriter` that streams an upload straight into a
  Dropbox upload session — the bytes never touch your server's disk.

  LiveView's default writer spools each entry into a temporary file, so a
  500 MB upload is written to disk in full before `consume_uploaded_entry/3`
  can hand it to `Magpie.Files.upload_file/4`. This writer skips that round
  trip: chunks are buffered in memory up to `:chunk_size` and appended to an
  upload session as they arrive.

  ## Usage

      socket =
        allow_upload(socket, :report,
          accept: ~w(.pdf),
          max_file_size: 500_000_000,
          writer: fn _name, entry, _socket ->
            {Magpie.LiveView.UploadWriter,
             client: MyApp.dropbox_client(), path: "/Reports/" <> entry.client_name}
          end
        )

  `consume_uploaded_entries/3` then receives whatever `meta/1` returns, so the
  Dropbox metadata of the committed file is already there — nothing left to
  upload:

      consume_uploaded_entries(socket, :report, fn %{metadata: metadata}, _entry ->
        {:ok, metadata}
      end)

  ## Options

    * `:client` (required) — a `Magpie.Client`
    * `:path` (required) — the destination path in Dropbox
    * `:chunk_size` — bytes buffered before each append (default 8 MiB).
      Dropbox wants every append but the last to be a multiple of 4 MiB, so
      keep this a multiple of 4 MiB.
    * `:mode` — `"add"` (default) or `"overwrite"`
    * `:autorename` — default `true`
    * `:mute` — default `false`

  ## Notes

  Magpie does not depend on `:phoenix_live_view` — the behaviour is a plain
  set of callbacks, and declaring it would drag Phoenix into every project
  that only wants a Dropbox client. The callbacks below match
  `Phoenix.LiveView.UploadWriter` as of LiveView 1.0.

  They run in the per-entry `Phoenix.LiveView.UploadChannel` process, not in
  the LiveView itself: a slow append backpressures that one upload instead of
  blocking the rest of the page.

  The session is opened in `init/1`. A cancelled or failed upload leaves it
  dangling, which is harmless — Dropbox drops incomplete sessions after 7 days
  and nothing is committed without a `finish`.
  """

  alias Magpie.Files.UploadSession

  @chunk_size 8 * 1024 * 1024

  @doc """
  Opens the upload session. See the module docs for the accepted options.
  """
  def init(opts) do
    client = Keyword.fetch!(opts, :client)

    commit = %{
      "path" => Keyword.fetch!(opts, :path),
      "mode" => Keyword.get(opts, :mode, "add"),
      "autorename" => Keyword.get(opts, :autorename, true),
      "mute" => Keyword.get(opts, :mute, false)
    }

    case UploadSession.start_data(client, "") do
      {:ok, %{"session_id" => session_id}} ->
        {:ok,
         %{
           client: client,
           session_id: session_id,
           commit: commit,
           chunk_size: Keyword.get(opts, :chunk_size, @chunk_size),
           buffer: <<>>,
           offset: 0,
           metadata: nil
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  What `consume_uploaded_entries/3` receives: the destination path and the
  Dropbox metadata of the committed file.
  """
  def meta(state), do: %{path: state.commit["path"], metadata: state.metadata}

  @doc """
  Buffers `data`, appending to the session whenever `:chunk_size` is reached.
  """
  def write_chunk(data, state), do: flush(%{state | buffer: state.buffer <> data})

  @doc """
  Commits the session on `:done`, sending whatever is left in the buffer along
  with the finish call. Any other reason (`:cancel`, an upstream error) leaves
  the session uncommitted.
  """
  def close(state, :done) do
    %{buffer: buffer, offset: offset} = state

    case UploadSession.finish_data(state.client, state.session_id, offset, state.commit, buffer) do
      {:ok, metadata} ->
        {:ok, %{state | buffer: <<>>, offset: offset + byte_size(buffer), metadata: metadata}}

      {:error, error} ->
        {:error, error}
    end
  end

  def close(state, _reason), do: {:ok, state}

  defp flush(%{buffer: buffer, chunk_size: chunk_size} = state)
       when byte_size(buffer) >= chunk_size do
    <<chunk::binary-size(^chunk_size), rest::binary>> = buffer

    case UploadSession.append_data(state.client, state.session_id, state.offset, chunk) do
      {:ok, _} -> flush(%{state | buffer: rest, offset: state.offset + chunk_size})
      {:error, error} -> {:error, error, state}
    end
  end

  defp flush(state), do: {:ok, state}
end
