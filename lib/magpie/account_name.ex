defmodule Magpie.Name do
  @moduledoc """
  Struct for the `name` field of a Dropbox account.
  """
  @type t :: %__MODULE__{}

  defstruct display_name: nil,
            familiar_name: nil,
            given_name: nil,
            surname: nil
end
