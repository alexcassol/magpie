defmodule Magpie.Account do
  @moduledoc """
  Struct for a Dropbox user account (`/users/get_account`).
  """
  @type t :: %__MODULE__{}

  defstruct account_id: nil,
            account_type: nil,
            country: nil,
            disabled: nil,
            email: nil,
            email_verified: nil,
            is_paired: nil,
            locale: nil,
            referral_link: nil,
            name: Magpie.Name
end
