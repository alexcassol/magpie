defmodule Magpie.CursorError do
  @moduledoc """
  Dropbox invalidated a listing cursor, possibly because it expired.

  `reason` is `:reset`; `rebuild_required` is true. `error` preserves the original
  `Magpie.Error` including request diagnostics. Reconcile a fresh full listing
  against your local state before publishing a replacement checkpoint. Simply
  discarding the old cursor may lose deletions. No automatic recovery occurs.
  """
  defexception [:error, reason: :reset, rebuild_required: true]
  @type t :: %__MODULE__{error: Magpie.Error.t(), reason: :reset, rebuild_required: true}

  @impl true
  def message(_), do: "Dropbox listing cursor was invalidated; state rebuild required"
end
