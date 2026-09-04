defmodule Magpie.Folder do
  @moduledoc """
  Legacy struct for folder metadata, kept for
  `Magpie.Files.create_folder_to_struct/2` and
  `Magpie.Files.delete_folder_to_struct/2`.

  Deprecated since 0.4.0: the files endpoints now return
  `Magpie.FolderMetadata` (and `Magpie.FileMetadata`) directly — see
  `Magpie.Metadata`.
  """
  @type t :: %__MODULE__{}

  defstruct id: nil,
            name: nil,
            path_display: nil,
            path_lower: nil
end
