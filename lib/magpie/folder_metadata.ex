defmodule Magpie.FolderMetadata do
  @moduledoc """
  A folder in the user's Dropbox, as returned by the `files` endpoints
  (`/files/get_metadata`, `/files/list_folder`, `/files/create_folder_v2`, ...).

  Built by `Magpie.Metadata.decode/1`:

      {:ok, %Magpie.FolderMetadata{id: "id:" <> _, name: "Photos"}} =
        Magpie.Files.create_folder(client, "/Photos")

  `sharing_info` (a `FolderSharingInfo` object, present when the folder is
  shared) and `property_groups` are kept as the raw maps Dropbox returned.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          id: String.t(),
          path_lower: String.t() | nil,
          path_display: String.t() | nil,
          shared_folder_id: String.t() | nil,
          parent_shared_folder_id: String.t() | nil,
          preview_url: String.t() | nil,
          sharing_info: map() | nil,
          property_groups: [map()] | nil
        }

  defstruct name: nil,
            id: nil,
            path_lower: nil,
            path_display: nil,
            shared_folder_id: nil,
            parent_shared_folder_id: nil,
            preview_url: nil,
            sharing_info: nil,
            property_groups: nil

  @doc """
  Builds the struct from a decoded `FolderMetadata` JSON object.

  Prefer `Magpie.Metadata.decode/1`, which also handles files and deleted
  entries by looking at the `".tag"`.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      name: map["name"],
      id: map["id"],
      path_lower: map["path_lower"],
      path_display: map["path_display"],
      shared_folder_id: map["shared_folder_id"],
      parent_shared_folder_id: map["parent_shared_folder_id"],
      preview_url: map["preview_url"],
      sharing_info: map["sharing_info"],
      property_groups: map["property_groups"]
    }
  end
end
