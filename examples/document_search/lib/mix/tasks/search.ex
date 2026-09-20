defmodule Mix.Tasks.Search do
  use Mix.Task
  @shortdoc "Sync Dropbox documents, search locally, or inspect index status"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, command, invalid} =
      OptionParser.parse(args, strict: [index: :string, rebuild: :boolean])

    unless invalid == [], do: usage!()
    {:ok, db} = DocumentSearch.Index.open(Keyword.get(opts, :index, "var/documents.sqlite3"))

    try do
      case command do
        ["sync", root] ->
          case DocumentSearch.sync(client(), db, root,
                 rebuild: Keyword.get(opts, :rebuild, false)
               ) do
            {:ok, status} ->
              Mix.shell().info(inspect(status, pretty: true))

            {:error, :cursor_reset_rebuild_required} ->
              Mix.raise(
                "Cursor expired. Repeat sync with --rebuild; the old index stays available until it succeeds."
              )

            {:error, reason} ->
              Mix.raise("Indexing failed: #{inspect(reason)}")
          end

        ["query", query] ->
          results = DocumentSearch.Index.search(db, query)
          if results == [], do: Mix.shell().info("No matching documents.")

          Enum.each(results, fn hit ->
            Mix.shell().info(
              "#{hit.title}\n#{hit.path}\n#{hit.excerpt}\n#{hit.id} @ rev:#{hit.rev}\n"
            )
          end)

        ["status"] ->
          Mix.shell().info(inspect(DocumentSearch.Index.status(db), pretty: true))

        _ ->
          usage!()
      end
    after
      DocumentSearch.Index.close(db)
    end
  end

  defp client do
    if token = System.get_env("DROPBOX_REFRESH_TOKEN") do
      Magpie.Client.new(
        refresh_token: token,
        app_key: System.fetch_env!("DROPBOX_APP_KEY"),
        app_secret: System.fetch_env!("DROPBOX_APP_SECRET"),
        timeout: 60_000
      )
    else
      Magpie.Client.new(System.fetch_env!("DROPBOX_ACCESS_TOKEN"), timeout: 60_000)
    end
  end

  defp usage!,
    do:
      Mix.raise("Usage: mix search sync ROOT [--rebuild] | query 'WORDS' | status [--index PATH]")
end
