defmodule Magpie.Paper.Docs do
  @moduledoc """
  This namespace contains endpoints and data types for
  managing docs and folders in Dropbox Paper.
  """
  import Magpie

  @doc """
  Marks the given Paper doc as archived.

  ## Example

    Magpie.Paper.Docs.docs_archive client, ""

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#paper-docs-create
  """
  def docs_archive(client, doc_id) do
    body = %{"doc_id" => doc_id}
    post(client, "/paper/docs/archive", body)
  end

  @doc """
  Creates a new Paper doc with the provided content.

  ## Example

    Magpie.Paper.Docs.docs_create client, "", "", ""

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#paper-docs-create
  """
  def docs_create(client, import_format, parent_folder_id, file) do
    dropbox_headers = %{
      :import_format => import_format,
      :parent_folder_id => parent_folder_id
    }

    headers = %{
      "Dropbox-API-Arg" => Jason.encode!(dropbox_headers),
      "Content-Type" => "application/octet-stream"
    }

    upload_request(
      client,
      Application.get_env(:magpie, :base_url),
      "/paper/docs/create",
      file,
      headers
    )
  end

  @doc """
  Exports and downloads Paper doc either as HTML or markdown.

  ## Example

    Magpie.Paper.Docs.docs_download client, "", ""

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#paper-docs-download
  """
  def docs_download(client, doc_id, export_format) do
    dropbox_headers = %{
      :doc_id => doc_id,
      :export_format => export_format
    }

    headers = %{"Dropbox-API-Arg" => Jason.encode!(dropbox_headers)}

    download_request(
      client,
      Application.get_env(:magpie, :base_url),
      "/paper/docs/download",
      [],
      headers
    )
  end

  @doc """
  Retrieves folder information for the given Paper doc.

  ## Example

    Magpie.Paper.Docs.get_folder_info client, "", ""

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#paper-docs-get_folder_info
  """
  def get_folder_info(client, doc_id) do
    body = %{"doc_id" => doc_id}
    post(client, "/paper/docs/get_folder_info", body)
  end

  @doc """
  Return the list of all Paper docs according to the argument specifications.

  ## Example

    Magpie.Paper.Docs.docs_list client

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#paper-docs-list
  """
  def docs_list(
        client,
        filter_by \\ "docs_created",
        sort_by \\ "modified",
        sort_order \\ "descending",
        limit \\ 100
      ) do
    body = %{
      "filter_by" => filter_by,
      "sort_by" => sort_by,
      "sort_order" => sort_order,
      "limit" => limit
    }

    post(client, "/paper/docs/list", body)
  end

  @doc """
  Permanently deletes the given Paper doc.

  ## Example

    Magpie.Paper.Docs.permanently_delete client

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#paper-docs-list
  """
  def permanently_delete(client, doc_id) do
    body = %{"doc_id" => doc_id}
    post(client, "/paper/docs/permanently_delete", body)
  end

  @doc """
  Updates an existing Paper doc with the provided content.

  ## Example

    Magpie.Paper.Docs.docs_update client, "", "", "", "", ""

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#paper-docs-download
  """
  def docs_update(client, doc_id, doc_update_policy, revision, import_format, file) do
    dropbox_headers = %{
      :doc_id => doc_id,
      :doc_update_policy => doc_update_policy,
      :revision => revision,
      :import_format => import_format
    }

    headers = %{"Dropbox-API-Arg" => Jason.encode!(dropbox_headers)}

    upload_request(
      client,
      Application.get_env(:magpie, :base_url),
      "/paper/docs/update",
      file,
      headers
    )
  end
end
