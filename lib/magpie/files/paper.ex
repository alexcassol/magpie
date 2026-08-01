defmodule Magpie.Files.Paper do
  @moduledoc """
  Paper docs stored as files (`/files/paper/*`) — the replacement for the
  deprecated `/paper/docs/*` API. Content is uploaded from a local file.
  """
  import Magpie

  @doc """
  Creates a new Paper doc at `path` importing the local file `file`
  (`import_format`: `"html"`, `"markdown"` or `"plain_text"`).

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-paper-create
  """
  def create(client, path, file, import_format \\ "markdown") do
    arg = %{"path" => path, "import_format" => import_format}

    headers = %{
      "Dropbox-API-Arg" => Jason.encode!(arg),
      "Content-Type" => "application/octet-stream"
    }

    upload_request(client, upload_url(), "files/paper/create", file, headers)
  end

  @doc """
  Updates an existing Paper doc with the contents of the local file `file`.
  `doc_update_policy` is `"update"` or `"overwrite"`; `opts` accepts
  `"paper_revision"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#files-paper-update
  """
  def update(
        client,
        path,
        file,
        import_format \\ "markdown",
        doc_update_policy \\ "update",
        opts \\ %{}
      ) do
    arg =
      Map.merge(
        %{
          "path" => path,
          "import_format" => import_format,
          "doc_update_policy" => doc_update_policy
        },
        opts
      )

    headers = %{
      "Dropbox-API-Arg" => Jason.encode!(arg),
      "Content-Type" => "application/octet-stream"
    }

    upload_request(client, upload_url(), "files/paper/update", file, headers)
  end
end
