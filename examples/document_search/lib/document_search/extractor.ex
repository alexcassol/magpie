defmodule DocumentSearch.Extractor do
  @moduledoc "Extracts UTF-8 text and Markdown. Other formats need an application-owned adapter."
  @max_bytes 2 * 1024 * 1024

  def accept(file) do
    cond do
      not file.is_downloadable ->
        {:skip, "requires_export"}

      file.size > @max_bytes ->
        {:skip, "too_large"}

      String.downcase(Path.extname(file.name)) not in [".txt", ".md", ".markdown"] ->
        {:skip, "unsupported_format"}

      true ->
        :ok
    end
  end

  def extract(body, name) do
    cond do
      byte_size(body) > @max_bytes ->
        {:skip, "too_large"}

      not String.valid?(body) or String.contains?(body, <<0>>) ->
        {:skip, "not_utf8_text"}

      String.trim(body) == "" ->
        {:skip, "empty_text"}

      true ->
        title =
          case Regex.run(~r/^#\s+(.+)$/m, body, capture: :all_but_first) do
            [heading] -> String.trim(heading)
            _ -> Path.rootname(name)
          end

        {:ok, %{title: title, body: body}}
    end
  end
end
