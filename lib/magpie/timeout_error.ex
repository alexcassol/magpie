defmodule Magpie.TimeoutError do
  @moduledoc """
  The configured execution budget was exhausted.

  A timed-out mutation may already have been accepted by Dropbox. Check its
  result before repeating it. This error never makes a mutation retryable.
  """
  defexception [:endpoint, :timeout]
  @type t :: %__MODULE__{endpoint: String.t() | nil, timeout: non_neg_integer() | nil}

  @impl true
  def message(_error), do: "Magpie execution budget exhausted"
end
