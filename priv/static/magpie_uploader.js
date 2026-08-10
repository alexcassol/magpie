// Magpie — client half of the direct browser → Dropbox upload.
//
// The server mints a one-time link with `Magpie.LiveView.presign_upload/4`
// and returns it as `{uploader: "Magpie", url: link, path: path}`. This
// uploader posts the file's raw bytes to that link, so they never pass
// through your server.
//
// Register it on the LiveSocket:
//
//     import Uploaders from "../../deps/magpie/priv/static/magpie_uploader"
//
//     let liveSocket = new LiveSocket("/live", Socket, {
//       uploaders: Uploaders,
//       params: {_csrf_token: csrfToken}
//     })

let Uploaders = {}

Uploaders.Magpie = function (entries, onViewError) {
  entries.forEach(entry => {
    let xhr = new XMLHttpRequest()

    // Abort in flight if the LiveView goes away.
    onViewError(() => xhr.abort())

    xhr.onload = () => (xhr.status === 200 ? entry.progress(100) : entry.error())
    xhr.onerror = () => entry.error()

    xhr.upload.addEventListener("progress", event => {
      if (event.lengthComputable) {
        let percent = Math.round((event.loaded / event.total) * 100)
        // 100 is reserved for onload — it is what completes the entry.
        if (percent < 100) { entry.progress(percent) }
      }
    })

    // A temporary upload link takes the bare bytes, not a multipart form.
    // The destination path is already baked into the link.
    xhr.open("POST", entry.meta.url, true)
    xhr.setRequestHeader("Content-Type", "application/octet-stream")
    xhr.send(entry.file)
  })
}

export default Uploaders
