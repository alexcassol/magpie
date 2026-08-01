defmodule Magpie.Pager do
  @moduledoc """
  Turns Dropbox cursor-based pagination into a lazy `Stream`.

  Many Dropbox endpoints return one page of results plus a `"cursor"` (and
  usually a `"has_more"` flag), expecting you to call a `/continue` variant
  until the listing is exhausted. `stream/3` hides that loop behind a regular
  Elixir `Stream`, so consumers just use `Enum`/`Stream` functions and pages
  are fetched on demand:

      client
      |> Magpie.Files.ListFolder.stream("/Photos")
      |> Stream.filter(&(&1[".tag"] == "file"))
      |> Enum.take(100)

  Ready-made wrappers: `Magpie.Files.ListFolder.stream/3`,
  `Magpie.Files.search_stream/3`, `Magpie.Sharing.list_folders_stream/2` and
  `Magpie.FileRequests.stream/2`. For any other paginated endpoint, build
  your own with `stream/3`.

  Because a `Stream` cannot return an error tuple mid-enumeration, API
  errors raise `Magpie.Error` while the stream is being consumed.
  """

  @doc """
  Builds a lazy `Stream` of items out of a paginated endpoint.

    * `first_fun` — zero-arity function that fetches the first page
    * `continue_fun` — one-arity function that takes a cursor and fetches
      the next page
    * `opts`:
      * `:items_key` — key holding the page's item list (default `"entries"`)
      * `:cursor_key` — key holding the cursor (default `"cursor"`)
      * `:has_more_key` — key flagging more pages (default `"has_more"`;
        when the key is absent, pagination continues while a cursor is
        present)

  ## Example

      Magpie.Pager.stream(
        fn -> Magpie.Files.ListFolder.list_folder(client, "/Photos") end,
        fn cursor -> Magpie.Files.ListFolder.list_folder_continue(client, cursor) end
      )

  """
  def stream(first_fun, continue_fun, opts \\ [])
      when is_function(first_fun, 0) and is_function(continue_fun, 1) do
    items_key = Keyword.get(opts, :items_key, "entries")
    cursor_key = Keyword.get(opts, :cursor_key, "cursor")
    has_more_key = Keyword.get(opts, :has_more_key, "has_more")

    Stream.resource(
      fn -> :first end,
      fn
        :first -> first_fun.() |> emit(items_key, cursor_key, has_more_key)
        {:cursor, cursor} -> continue_fun.(cursor) |> emit(items_key, cursor_key, has_more_key)
        :done -> {:halt, :done}
      end,
      fn _acc -> :ok end
    )
  end

  defp emit({:ok, page}, items_key, cursor_key, has_more_key) do
    items = Map.get(page, items_key, [])
    {items, next_acc(Map.get(page, cursor_key), Map.get(page, has_more_key))}
  end

  defp emit({:error, %Magpie.Error{} = error}, _items_key, _cursor_key, _has_more_key),
    do: raise(error)

  # has_more absent: keep going while there is a cursor
  defp next_acc(nil, _has_more), do: :done
  defp next_acc(_cursor, false), do: :done
  defp next_acc(cursor, _has_more), do: {:cursor, cursor}
end
