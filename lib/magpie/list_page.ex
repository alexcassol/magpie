defmodule Magpie.ListPage do
  @moduledoc """
  One listing page returned by `Magpie.Storage.list_page/3` and
  `Magpie.Storage.continue_list/3`.

  `entries` uses existing metadata types (unknown Dropbox tags remain raw maps).
  `has_more` means drain another page now; even when false, retain `cursor`
  for later polling. The cursor is opaque and tied to the original account,
  namespace and listing options. Magpie neither stores nor acknowledges it.
  Pages describe state changes, not a complete ordered event history; an entry
  alone does not distinguish creation, modification or a move.
  """
  @enforce_keys [:entries, :cursor, :has_more]
  defstruct [:entries, :cursor, :has_more]

  @type t :: %__MODULE__{
          entries: [Magpie.Metadata.t() | map()],
          cursor: binary(),
          has_more: boolean()
        }

  @doc false
  def from_result({:ok, %{"entries" => entries, "cursor" => cursor, "has_more" => more}}),
    do: {:ok, %__MODULE__{entries: entries, cursor: cursor, has_more: more}}

  def from_result(
        {:error, %Magpie.Error{status: 409, body: %{"error" => %{".tag" => "reset"}}} = error}
      ),
      do: {:error, %Magpie.CursorError{error: error}}

  def from_result({:error, _} = error), do: error
end
