defmodule Magpie.FileMetadata do
  @moduledoc """
  A file in the user's Dropbox, as returned by the `files` endpoints
  (`/files/get_metadata`, `/files/list_folder`, `/files/upload`, ...).

  Built by `Magpie.Metadata.decode/1`. Timestamps are `DateTime` structs and
  `content_hash` is a first-class field, so integrity checks and "has it
  changed?" comparisons need no digging through string keys:

      {:ok, %Magpie.FileMetadata{} = file} = Magpie.Files.get_metadata(client, "/report.pdf")

      file.size
      # => 48_213

      DateTime.diff(DateTime.utc_now(), file.server_modified, :day)
      # => 3

      file.content_hash == Magpie.Metadata.content_hash(File.read!("report.pdf"))
      # => true

  Nested objects Dropbox may attach (`sharing_info`, `media_info`,
  `symlink_info`, `export_info`, `file_lock_info` and `property_groups`)
  are kept as the raw maps Dropbox returned.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          id: String.t(),
          path_lower: String.t() | nil,
          path_display: String.t() | nil,
          client_modified: DateTime.t() | nil,
          server_modified: DateTime.t() | nil,
          rev: String.t(),
          size: non_neg_integer(),
          content_hash: String.t() | nil,
          is_downloadable: boolean(),
          has_explicit_shared_members: boolean() | nil,
          parent_shared_folder_id: String.t() | nil,
          preview_url: String.t() | nil,
          sharing_info: map() | nil,
          media_info: map() | nil,
          symlink_info: map() | nil,
          export_info: map() | nil,
          file_lock_info: map() | nil,
          property_groups: [map()] | nil
        }

  defstruct name: nil,
            id: nil,
            path_lower: nil,
            path_display: nil,
            client_modified: nil,
            server_modified: nil,
            rev: nil,
            size: nil,
            content_hash: nil,
            is_downloadable: true,
            has_explicit_shared_members: nil,
            parent_shared_folder_id: nil,
            preview_url: nil,
            sharing_info: nil,
            media_info: nil,
            symlink_info: nil,
            export_info: nil,
            file_lock_info: nil,
            property_groups: nil

  @doc """
  Builds the struct from a decoded `FileMetadata` JSON object.

  Prefer `Magpie.Metadata.decode/1`, which also handles folders and deleted
  entries by looking at the `".tag"`.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      name: map["name"],
      id: map["id"],
      path_lower: map["path_lower"],
      path_display: map["path_display"],
      client_modified: Magpie.Metadata.parse_timestamp(map["client_modified"]),
      server_modified: Magpie.Metadata.parse_timestamp(map["server_modified"]),
      rev: map["rev"],
      size: map["size"],
      content_hash: map["content_hash"],
      is_downloadable: Map.get(map, "is_downloadable", true),
      has_explicit_shared_members: map["has_explicit_shared_members"],
      parent_shared_folder_id: map["parent_shared_folder_id"],
      preview_url: map["preview_url"],
      sharing_info: map["sharing_info"],
      media_info: map["media_info"],
      symlink_info: map["symlink_info"],
      export_info: map["export_info"],
      file_lock_info: map["file_lock_info"],
      property_groups: map["property_groups"]
    }
  end
end
