defmodule Magpie.Utils do
  @moduledoc """
  Small helpers shared across the API modules.
  """

  # Elixir 1.15 needs the old argument order, which 1.20 deprecates.
  if Version.match?(System.version(), ">= 1.16.0-dev") do
    @doc false
    def file_stream(path, bytes), do: File.stream!(path, bytes)
  else
    @doc false
    def file_stream(path, bytes), do: File.stream!(path, [], bytes)
  end

  def to_struct(kind, attrs) do
    struct = struct(kind)

    Enum.reduce(Map.to_list(struct), struct, fn {k, _}, acc ->
      case Map.fetch(attrs, Atom.to_string(k)) do
        {:ok, v} -> %{acc | k => v}
        :error -> acc
      end
    end)
  end

  def get_header(headers, key) do
    headers
    |> Enum.filter(fn {k, _} -> k == key end)
    |> hd
    |> elem(1)
  end
end
