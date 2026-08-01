# Magpie 🐦

Elixir client for the [Dropbox API v2](https://www.dropbox.com/developers/documentation/http/documentation), built on [Req](https://hexdocs.pm/req).

Like the bird, Magpie collects and stashes your things — in your Dropbox.

## Installation

Add `magpie` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:magpie, git: "https://github.com/alexcassol/magpie.git"}
  ]
end
```

> Publishing to Hex is planned; once published this becomes `{:magpie, "~> 0.1"}`.

Then configure the Dropbox endpoints in your `config/config.exs`:

```elixir
config :magpie,
  base_url: "https://api.dropboxapi.com/2",
  upload_url: "https://content.dropboxapi.com/2/"
```

## Usage

```elixir
client = Magpie.Client.new("DROPBOX_ACCESS_TOKEN")

# Who am I?
Magpie.Users.current_account(client)

# List a folder
{:ok, %{"entries" => entries}} = Magpie.Files.ListFolder.list_folder(client, "/Photos")

# Create a folder
{:ok, %{"metadata" => folder}} = Magpie.Files.create_folder(client, "/Backup")

# Upload a file
Magpie.Files.upload(client, "/Backup/report.pdf", "priv/report.pdf")

# Download a file
%{body: contents} = Magpie.Files.download(client, "/Backup/report.pdf")
```

Successful calls return `{:ok, body}`; API errors return `{{:status_code, code}, body}`.

## Covered endpoints

- **files** — upload, download, copy/move/delete (incl. batch), list_folder (+ continue, cursor, longpoll), metadata, search, thumbnails, previews, temporary links, save_url, upload sessions
- **users** — get_account, get_account_batch, get_current_account, get_space_usage
- **file_requests** — create, get, list, update
- **paper** — docs create/list/download/archive, folder users, sharing policy

## Testing

The test suite runs entirely offline using [`Req.Test`](https://hexdocs.pm/req/Req.Test.html) stubs:

```sh
mix test
```

## Origin

Magpie started as a fork of [sger/elixir_dropbox](https://hex.pm/packages/elixir_dropbox), which is no longer maintained (its GitHub repository has been deleted). The code has since been modernized: HTTPoison/Poison were replaced with Req/Jason, and the test suite was rewritten with Req.Test. Credit and thanks to the original Elixir Dropbox contributors.

## License

MIT — see [LICENSE](LICENSE).
