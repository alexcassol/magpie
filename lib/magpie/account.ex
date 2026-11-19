defmodule Magpie.Account do
  @moduledoc """
  Struct for a Dropbox user account (`/users/get_account`).

  Key your own records on `account_id`, which Dropbox guarantees to be unique
  and stable. `email` is neither: users can change it and Dropbox may reuse an
  address for a different account, so treat it as contact data only.
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
