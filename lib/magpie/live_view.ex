defmodule Magpie.LiveView do
  @moduledoc """
  Direct browser → Dropbox uploads for `Phoenix.LiveView`.

  `Magpie.LiveView.UploadWriter` keeps the bytes off your disk but still
  routes them through your server. `presign_upload/4` removes the server from
  the path entirely: it mints a one-time upload link with
  `Magpie.Files.get_temporary_upload_link/3` and hands it to the browser,
  which posts the file straight to Dropbox.

      def mount(_params, _session, socket) do
        {:ok, allow_upload(socket, :avatar, accept: ~w(.jpg .png), external: &presign/2)}
      end

      defp presign(entry, socket) do
        Magpie.LiveView.presign_upload(MyApp.dropbox_client(), entry, socket,
          path: "/Avatars/" <> entry.client_name
        )
      end

  The client-side half lives in `priv/static/magpie_uploader.js`. Register it
  on your `LiveSocket` under the name Magpie returns in the metadata:

      import Uploaders from "../../deps/magpie/priv/static/magpie_uploader"

      let liveSocket = new LiveSocket("/live", Socket, {
        uploaders: Uploaders,
        params: {_csrf_token: csrfToken}
      })

  Once the entry completes, `consume_uploaded_entries/3` receives the metadata
  returned below — the file is already in Dropbox:

      consume_uploaded_entries(socket, :avatar, fn %{path: path}, _entry ->
        {:ok, path}
      end)

  ## Trade-offs

  The destination is baked into the link when it is minted, so the browser
  cannot redirect the upload somewhere else — but it also cannot be changed
  after the fact, and the link is single-use.

  Dropbox caps a temporary upload link at 150 MB, the same limit as a
  single-request upload. `presign_upload/4` rejects larger entries up front
  rather than handing out a link that is guaranteed to fail; for those, fall
  back to `Magpie.LiveView.UploadWriter`, which chunks through an upload
  session.

  Magpie does not depend on `:phoenix_live_view` — `entry` is only read for
  `client_name` and `client_size`, and `socket` is passed through untouched.
  """

  alias Magpie.Files

  @uploader "Magpie"

  # The ceiling on a single-request upload, temporary links included.
  @max_size 150 * 1024 * 1024

  @doc """
  Mints a one-time upload link for `entry` and returns it as LiveView external
  uploader metadata.

  Returns `{:ok, meta, socket}` with `%{uploader: "Magpie", url: link, path: path}`,
  or `{:error, %{error: reason}, socket}` — both shapes `allow_upload/3`
  expects from an `:external` function.

  ## Options

    * `:path` — the destination in Dropbox (defaults to `entry.client_name`
      at the root)
    * `:duration` — how long the link stays valid, in seconds (default 4 hours,
      Dropbox's own default)
    * `:mode` — `"add"` (default) or `"overwrite"`
    * `:autorename` — default `true`
    * `:mute` — default `false`
  """
  def presign_upload(client, entry, socket, opts \\ [])

  def presign_upload(_client, %{client_size: size}, socket, _opts) when size > @max_size do
    {:error, %{error: "too_large_for_temporary_link"}, socket}
  end

  def presign_upload(client, entry, socket, opts) do
    path = Keyword.get_lazy(opts, :path, fn -> "/" <> entry.client_name end)

    commit = %{
      "path" => path,
      "mode" => Keyword.get(opts, :mode, "add"),
      "autorename" => Keyword.get(opts, :autorename, true),
      "mute" => Keyword.get(opts, :mute, false)
    }

    case Files.get_temporary_upload_link(client, commit, Keyword.get(opts, :duration, 14_400)) do
      {:ok, %{"link" => link}} ->
        {:ok, %{uploader: @uploader, url: link, path: path}, socket}

      {:error, error} ->
        {:error, %{error: error.summary || "upload_link_failed"}, socket}
    end
  end
end
