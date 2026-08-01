defmodule Magpie.SpaceUsage do
  @moduledoc """
  Struct for `/users/get_space_usage` responses.
  """
  defstruct used: nil,
            allocation: Magpie.Allocation
end
