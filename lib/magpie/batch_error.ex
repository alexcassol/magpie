defmodule Magpie.BatchError do
  @moduledoc "An isolated failure from a concurrent `Magpie.Storage` batch operation."

  defexception [:operation, :key, :reason]

  @impl true
  def message(%__MODULE__{operation: operation, key: key, reason: reason}),
    do: "#{operation} failed for #{inspect(key)}: #{inspect(reason)}"
end
