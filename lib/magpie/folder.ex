defmodule Magpie.Folder do
  @moduledoc """
  Struct for folder metadata returned by the files endpoints.
  """
  defstruct id: nil,
            name: nil,
            path_display: nil,
            path_lower: nil
end
