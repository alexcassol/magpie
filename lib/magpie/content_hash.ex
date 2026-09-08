defmodule Magpie.ContentHash do
  @moduledoc false

  @block_size 4 * 1024 * 1024

  def new, do: {[], <<>>}

  def update({digests, buffer}, chunk) do
    hash_blocks(buffer <> IO.iodata_to_binary(chunk), digests)
  end

  def finalize({digests, rest}) do
    digests = if rest == <<>>, do: digests, else: [sha256(rest) | digests]

    digests
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> sha256()
    |> Base.encode16(case: :lower)
  end

  defp hash_blocks(<<block::binary-size(@block_size), rest::binary>>, digests),
    do: hash_blocks(rest, [sha256(block) | digests])

  defp hash_blocks(rest, digests), do: {digests, rest}

  defp sha256(data), do: :crypto.hash(:sha256, data)
end
