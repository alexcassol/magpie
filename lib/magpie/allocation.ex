defmodule Magpie.Allocation do
  @moduledoc """
  Struct for the space allocation section of `/users/get_space_usage`.
  """
  @type t :: %__MODULE__{}

  defstruct tag: nil,
            allocated: nil
end
