defmodule Magpie.IntegrityError do
  @moduledoc """
  Returned when Dropbox metadata does not match the content Magpie uploaded.
  """

  defexception [:path, :expected, :actual]

  @type t :: %__MODULE__{
          path: binary(),
          expected: binary(),
          actual: binary() | nil
        }

  @impl true
  def message(%__MODULE__{path: path, expected: expected, actual: actual}) do
    "content hash mismatch for #{path}: expected #{expected}, got #{inspect(actual)}"
  end
end
