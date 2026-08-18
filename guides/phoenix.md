# Phoenix & LiveView uploads

LiveView already owns the upload experience — `allow_upload/3`, drag & drop,
progress, validation. Magpie doesn't try to replace any of it; it only fills
the gap a Dropbox backend creates: getting the bytes into Dropbox without
spooling them to your server's disk, or without touching your server at all.

There are three ways to get an uploaded file into Dropbox, from simplest to
most hands-off:

| Approach | Bytes go through | Size limit | Use when |
| --- | --- | --- | --- |
| `Magpie.Files.upload_file/4` | your server, via a temp file | none | controllers, or LiveView when disk spooling is fine |
| `Magpie.LiveView.UploadWriter` | your server, in memory chunks | none | large LiveView uploads, no disk round trip |
| `Magpie.LiveView.presign_upload/4` | browser → Dropbox directly | 150 MB | keep your server out of the path entirely |

All examples assume a client that outlives the request. In a real
application that means a supervised `Magpie.Auth.TokenServer` and a small
helper — see the [OAuth guide](oauth.html):

```elixir
defmodule MyApp.Dropbox do
  def client, do: Magpie.Client.new(token_provider: {Magpie.Auth.TokenServer, MyApp.DropboxToken})
end
```

Magpie does **not** depend on `:phoenix_live_view` — the writer's callbacks
are a plain behaviour and the presign function only reads `client_name` and
`client_size` off the entry. Requiring the dependency would drag Phoenix into
every project that only wants a Dropbox client.

## From a controller

There is nothing to learn: `Plug.Upload` hands you a path and
`Magpie.Files.upload_file/4` takes it from there — a single request for
small files, a chunked upload session streamed from disk for big ones,
decided by size.

```elixir
defmodule MyAppWeb.ReportController do
  use MyAppWeb, :controller

  def create(conn, %{"file" => %Plug.Upload{} = upload}) do
    case Magpie.Files.upload_file(MyApp.Dropbox.client(), "/Uploads/" <> upload.filename, upload.path) do
      {:ok, metadata} ->
        conn
        |> put_flash(:info, "Uploaded #{metadata["name"]}")
        |> redirect(to: ~p"/reports")

      {:error, %Magpie.Error{} = error} ->
        conn
        |> put_flash(:error, "Dropbox refused the upload: #{Exception.message(error)}")
        |> redirect(to: ~p"/reports/new")
    end
  end
end
```

The same one-liner works inside `consume_uploaded_entry/3` in a LiveView —
but LiveView's default writer spools each entry to a temporary file first, so
a 500 MB upload hits your disk in full before a single byte reaches Dropbox.
The next section removes that round trip.

## LiveView, without touching the disk

`Magpie.LiveView.UploadWriter` is a `Phoenix.LiveView.UploadWriter` that
appends to a Dropbox upload session as the chunks arrive. By the time
`consume_uploaded_entries/3` runs, the file is already committed — the
Dropbox metadata comes back in `meta/1`, and there is nothing left to upload.

```elixir
defmodule MyAppWeb.ReportLive.Upload do
  use MyAppWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:uploaded, [])
     |> allow_upload(:report,
       accept: ~w(.pdf),
       max_entries: 5,
       max_file_size: 500_000_000,
       writer: fn _name, entry, _socket ->
         {Magpie.LiveView.UploadWriter,
          client: MyApp.Dropbox.client(), path: "/Reports/" <> entry.client_name}
       end
     )}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("save", _params, socket) do
    # `metadata` is the Dropbox FileMetadata of the committed file
    uploaded =
      consume_uploaded_entries(socket, :report, fn %{metadata: metadata}, _entry ->
        {:ok, metadata}
      end)

    {:noreply, update(socket, :uploaded, &(uploaded ++ &1))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <form id="upload-form" phx-submit="save" phx-change="validate">
      <.live_file_input upload={@uploads.report} />
      <button type="submit">Upload</button>
    </form>

    <div :for={entry <- @uploads.report.entries}>
      {entry.client_name} — {entry.progress}%
    </div>

    <ul>
      <li :for={file <- @uploaded}>{file["path_display"]}</li>
    </ul>
    """
  end
end
```

Options accepted by the writer:

* `:client` (required) — a `Magpie.Client`
* `:path` (required) — the destination path in Dropbox
* `:chunk_size` — bytes buffered before each append (default 8 MiB). Dropbox
  wants every append but the last to be a multiple of 4 MiB, so keep it one
* `:mode` — `"add"` (default) or `"overwrite"`
* `:autorename` — default `true`
* `:mute` — default `false`

A few things worth knowing:

* The callbacks run in the per-entry `Phoenix.LiveView.UploadChannel`
  process, not in the LiveView itself — a slow append backpressures that one
  upload instead of blocking the rest of the page.
* The upload session is opened in `init/1`. A cancelled or failed upload
  leaves it dangling, which is harmless: Dropbox drops incomplete sessions
  after 7 days and nothing is committed without a `finish`.
* Chunks are buffered in memory up to `:chunk_size`, so peak memory per
  in-flight entry is roughly one chunk.

## Direct browser → Dropbox uploads

To take your server out of the path completely, `Magpie.LiveView.presign_upload/4`
mints a one-time upload link with `Magpie.Files.get_temporary_upload_link/3`
and the browser posts the bytes straight to Dropbox
(`content.dropboxapi.com` allows the cross-origin request). It plugs into
LiveView's `:external` uploads:

```elixir
defmodule MyAppWeb.AvatarLive do
  use MyAppWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, allow_upload(socket, :avatar, accept: ~w(.jpg .png), external: &presign/2)}
  end

  defp presign(entry, socket) do
    Magpie.LiveView.presign_upload(MyApp.Dropbox.client(), entry, socket,
      path: "/Avatars/" <> entry.client_name
    )
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("save", _params, socket) do
    # The file is already in Dropbox — `path` is the destination baked into the link
    [path] = consume_uploaded_entries(socket, :avatar, fn %{path: path}, _entry -> {:ok, path} end)
    {:noreply, put_flash(socket, :info, "Saved to #{path}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <form id="avatar-form" phx-submit="save" phx-change="validate">
      <.live_file_input upload={@uploads.avatar} />
      <button type="submit">Upload</button>
    </form>

    <div :for={entry <- @uploads.avatar.entries}>
      {entry.client_name} — {entry.progress}%
    </div>
    """
  end
end
```

The client-side half ships in the package. Register it on your `LiveSocket`
under the uploader name Magpie returns in the metadata (`"Magpie"`):

```javascript
// assets/js/app.js
import Uploaders from "../../deps/magpie/priv/static/magpie_uploader"

let liveSocket = new LiveSocket("/live", Socket, {
  uploaders: Uploaders,
  params: {_csrf_token: csrfToken}
})
```

`presign_upload/4` accepts:

* `:path` — the destination in Dropbox (defaults to `entry.client_name` at
  the root)
* `:duration` — how long the link stays valid, in seconds (default 4 hours,
  Dropbox's own default)
* `:mode` — `"add"` (default) or `"overwrite"`
* `:autorename` — default `true`
* `:mute` — default `false`

Trade-offs to keep in mind:

* The destination path is baked into the link when it is minted, so the
  browser cannot redirect the upload elsewhere — but it also cannot be
  changed after the fact, and the link is single-use.
* Dropbox caps temporary upload links at **150 MB**, the same limit as a
  single-request upload. Larger entries are rejected at presign time with
  `%{error: "too_large_for_temporary_link"}` rather than handed a link that
  is guaranteed to fail — those belong on the `UploadWriter` path.
* Because the bytes never reach your server, `consume_uploaded_entries/3`
  only knows the requested `path` — call `Magpie.Files.get_metadata/2` if
  you need the size, `content_hash` or `rev` of the committed file (or its
  final name, when `autorename` had to step in).

## Testing

Both helpers go through the same `Req.Test` plumbing as the rest of Magpie,
so your LiveView tests never touch the network. With
`config :magpie, req_options: [plug: {Req.Test, Magpie}]` in `config/test.exs`,
`preflight_upload/1` runs the `:external` function and hands back the
presigned metadata:

```elixir
test "presigns a direct upload", %{conn: conn} do
  Req.Test.stub(Magpie, fn conn ->
    assert conn.request_path == "/files/get_temporary_upload_link"
    Req.Test.json(conn, %{"link" => "https://content.dropboxapi.com/apitul/1/abc"})
  end)

  {:ok, view, _html} = live(conn, ~p"/avatar")

  avatar =
    file_input(view, "#avatar-form", :avatar, [
      %{name: "me.png", content: <<137, 80, 78, 71>>, type: "image/png"}
    ])

  assert {:ok, %{entries: entries}} = preflight_upload(avatar)
  assert [%{uploader: "Magpie", url: "https://content.dropboxapi.com/" <> _, path: "/Avatars/me.png"}] =
           Map.values(entries)

  # External uploads never leave the test process — this only reports progress
  assert render_upload(avatar, "me.png") =~ "100%"
end
```

`Magpie.LiveView.UploadWriter` runs in the upload channel process, so it can
only see the stub if that process is allowed — `Req.Test.allow(Magpie, self(), pid)`
— or if the stub is shared for the whole test with
`Req.Test.set_req_test_to_shared/0`.
