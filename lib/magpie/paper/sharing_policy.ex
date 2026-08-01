defmodule Magpie.Paper.SharingPolicy do
  @moduledoc """
  """
  import Magpie

  @doc """
  Gets the default sharing policy for the given Paper doc.

  ## Example

    Magpie.Paper.SharingPolicy.get client, ""

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#paper-docs-sharing_policy-get
  """
  def get(client, doc_id) do
    body = %{"doc_id" => doc_id}
    post(client, "/paper/docs/sharing_policy/get", body)
  end

  @doc """
  Sets the default sharing policy for the given Paper doc.

  ## Example

    Magpie.Paper.SharingPolicy.set client, "HAOV9lRfMNj90iGLqMmC7", sharing_policy
  More info at: https://www.dropbox.com/developers/documentation/http/documentation#paper-docs-sharing_policy-set
  """
  def set(client, doc_id, sharing_policy) do
    body = %{"doc_id" => doc_id, "sharing_policy" => sharing_policy}
    post(client, "/paper/docs/sharing_policy/set", body)
  end
end
