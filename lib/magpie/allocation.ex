defmodule Magpie.Allocation do
  @moduledoc """
  Struct for the space allocation section of `/users/get_space_usage`.
  """
  defstruct tag: nil,
            allocated: nil
end
