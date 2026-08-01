defmodule Magpie.SpaceUsage do
  @moduledoc """
  Struct for `/users/get_space_usage` responses.
  """
  @type t :: %__MODULE__{}

  defstruct used: nil,
            allocation: Magpie.Allocation
end
