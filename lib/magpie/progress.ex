defmodule Magpie.Progress do
  @moduledoc false
  defstruct [:collectable, :callback, :total, :metadata]

  def wrap(collectable, callback, total, metadata)
      when is_nil(callback) or is_function(callback, 2),
      do: %__MODULE__{
        collectable: collectable,
        callback: callback,
        total: total,
        metadata: metadata
      }
end

defimpl Collectable, for: Magpie.Progress do
  def into(%Magpie.Progress{
        collectable: collectable,
        callback: callback,
        total: total,
        metadata: metadata
      }) do
    {acc, collector} = Collectable.into(collectable)

    wrapped = fn
      {inner, transferred}, {:cont, chunk} ->
        next = collector.(inner, {:cont, chunk})
        transferred = transferred + IO.iodata_length(chunk)

        :telemetry.execute(
          [:magpie, :transfer, :progress],
          %{transferred: transferred, total: total},
          metadata
        )

        if callback, do: callback.(transferred, total)
        {next, transferred}

      {inner, _transferred}, :done ->
        collector.(inner, :done)

      {inner, _transferred}, :halt ->
        collector.(inner, :halt)
    end

    {{acc, 0}, wrapped}
  end
end
