defmodule Magpie.Name do
  @moduledoc """
  Struct for the `name` field of a Dropbox account.
  """
  defstruct display_name: nil,
            familiar_name: nil,
            given_name: nil,
            surname: nil
end
