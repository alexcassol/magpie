defmodule Magpie.SharedLink do
  @moduledoc """
  Struct for a shared link returned by the sharing endpoints.
  """
  @type t :: %__MODULE__{}

  defstruct path: nil,
            url: nil
end
