defmodule Magpie.DeletedMetadata do
  @moduledoc """
  A deleted file or folder, as returned by `/files/list_folder` with
  `"include_deleted" => true` and by `/files/get_metadata` with
  `include_deleted`.

  Built by `Magpie.Metadata.decode/1`. Dropbox only reports the path of a
  deleted entry — there is no `id`, `size` or timestamp. `is_restorable`
  is filled in when the listing asked for `"include_restorable_info" => true`,
  and is `nil` otherwise.

      client
      |> Magpie.Files.ListFolder.stream("/Inbox", %{"include_deleted" => true})
      |> Enum.filter(&match?(%Magpie.DeletedMetadata{}, &1))
  """

  @type t :: %__MODULE__{
          name: String.t(),
          path_lower: String.t() | nil,
          path_display: String.t() | nil,
          parent_shared_folder_id: String.t() | nil,
          preview_url: String.t() | nil,
          is_restorable: boolean() | nil
        }

  defstruct name: nil,
            path_lower: nil,
            path_display: nil,
            parent_shared_folder_id: nil,
            preview_url: nil,
            is_restorable: nil

  @doc """
  Builds the struct from a decoded `DeletedMetadata` JSON object.

  Prefer `Magpie.Metadata.decode/1`, which also handles files and folders by
  looking at the `".tag"`.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      name: map["name"],
      path_lower: map["path_lower"],
      path_display: map["path_display"],
      parent_shared_folder_id: map["parent_shared_folder_id"],
      preview_url: map["preview_url"],
      is_restorable: map["is_restorable"]
    }
  end
end
