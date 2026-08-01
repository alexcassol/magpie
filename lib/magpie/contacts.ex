defmodule Magpie.Contacts do
  @moduledoc """
  Endpoints of the Dropbox `contacts` namespace.
  """
  import Magpie

  @doc """
  Removes all manually added contacts.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#contacts-delete_manual_contacts
  """
  def delete_manual_contacts(client) do
    post(client, "/contacts/delete_manual_contacts")
  end

  @doc """
  Removes manually added contacts from the given list of email addresses.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#contacts-delete_manual_contacts_batch
  """
  def delete_manual_contacts_batch(client, email_addresses) do
    post(client, "/contacts/delete_manual_contacts_batch", %{
      "email_addresses" => email_addresses
    })
  end
end
