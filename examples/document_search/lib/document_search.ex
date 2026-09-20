defmodule DocumentSearch do
  @moduledoc "Indexes one Dropbox folder recursively and keeps SQLite search results up to date."
  alias DocumentSearch.{Extractor, Index}
  alias Magpie.{DeletedMetadata, FileMetadata, FolderMetadata, Storage}
  alias Magpie.Files.ListFolder

  def sync(client, db, root, opts \\ []) do
    root = normalize_root!(root)

    with {:ok, %{"account_id" => account}} <- Magpie.Users.current_account(client) do
      Index.transaction(db, fn ->
        with :ok <- Index.bind(db, account, root) do
          if Keyword.get(opts, :rebuild, false), do: Index.clear(db)
          fetch_pages(client, db, root, Index.cursor(db))
        end
      end)
    end
  end

  defp fetch_pages(client, db, root, cursor) do
    response =
      if cursor do
        ListFolder.list_folder_continue(client, cursor)
      else
        ListFolder.list_folder(client, root, %{
          "recursive" => true,
          "include_deleted" => true,
          "limit" => 100
        })
      end

    case response do
      {:ok, %{"entries" => entries, "cursor" => next, "has_more" => more}} ->
        with :ok <- apply_entries(client, db, root, entries) do
          Index.checkpoint(db, next)
          if more, do: fetch_pages(client, db, root, next), else: {:ok, Index.status(db)}
        end

      {:error, %Magpie.Error{status: 409, body: %{"error" => %{".tag" => "reset"}}}} ->
        {:error, :cursor_reset_rebuild_required}

      error ->
        error
    end
  end

  defp apply_entries(client, db, root, entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      result =
        if inside?(entry.path_lower, root),
          do: apply_entry(client, db, entry),
          else: {:error, :entry_outside_root}

      case result do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp apply_entry(_client, db, %DeletedMetadata{path_lower: path}) do
    Index.remove_path(db, path)
    :ok
  end

  defp apply_entry(_client, db, %FolderMetadata{} = folder), do: Index.put_folder(db, folder)

  defp apply_entry(client, db, %FileMetadata{} = file) do
    previous = Index.node(db, file.id)

    result =
      case Extractor.accept(file) do
        {:skip, reason} ->
          {:skip, reason}

        :ok ->
          if previous && previous.rev == file.rev && previous.status == "indexed" do
            # A rename changes the path, not the downloaded revision.
            {:ok, %{title: title_for_rename(previous, file), body: previous.body}}
          else
            download_text(client, file)
          end
      end

    case result do
      {:ok, %{title: title, body: body}} ->
        Index.remove_path(db, file.path_lower)
        Index.put(db, file, "file", title, body, "indexed")

      {:skip, reason} ->
        Index.remove_path(db, file.path_lower)
        Index.put(db, file, "file", file.name, "", "skipped:" <> reason)

      {:error, reason} ->
        {:error, {:document_failed, file.id, reason}}
    end
  end

  defp title_for_rename(previous, file) do
    {:ok, extracted} = Extractor.extract(previous.body, file.name)
    extracted.title
  end

  defp download_text(client, file) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "magpie-index-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.mkdir!(directory)

    try do
      path = Path.join(directory, "document")

      with {:ok, _} <- Storage.download(client, "rev:" <> file.rev, path),
           {:ok, body} <- File.read(path) do
        if byte_size(body) == file.size and
             Magpie.Metadata.content_hash(body) == file.content_hash,
           do: Extractor.extract(body, file.name),
           else: {:error, :integrity_mismatch}
      end
    after
      File.rm_rf(directory)
    end
  end

  defp inside?(path, root) when is_binary(path),
    do: path == root or String.starts_with?(path, root <> "/")

  defp inside?(_, _), do: false

  defp normalize_root!(root) do
    root = String.trim_trailing(root, "/")

    unless String.starts_with?(root, "/") and root != "" and
             Enum.all?(
               String.split(String.trim_leading(root, "/"), "/"),
               &(&1 not in ["", ".", ".."])
             ) do
      raise ArgumentError, "choose a folder such as /Knowledge, not the entire Dropbox root"
    end

    String.downcase(root)
  end
end
