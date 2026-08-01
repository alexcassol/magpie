defmodule Magpie.Folder do
  @moduledoc """
  Struct for folder metadata returned by the files endpoints.
  """
  @type t :: %__MODULE__{}

  defstruct id: nil,
            name: nil,
            path_display: nil,
            path_lower: nil
end
