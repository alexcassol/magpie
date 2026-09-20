defmodule Mix.Tasks.Inbox.Run do
  use Mix.Task
  @shortdoc "Import CSV orders once, or keep scanning with --watch"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [root: :string, state: :string, watch: :boolean])

    if rest != [] or invalid != [],
      do:
        Mix.raise(
          "Usage: mix inbox.run [--root /MagpieOrders] [--state var/orders.json] [--watch]"
        )

    root = Keyword.get(opts, :root, "/MagpieOrders")
    {:ok, journal} = OrderInbox.Journal.start_link(Keyword.get(opts, :state, "var/orders.json"))
    client = client()
    :ok = OrderInbox.setup(client, root)

    if opts[:watch] do
      {:ok, _worker} = OrderInbox.Worker.start_link(client: client, journal: journal, root: root)
      Process.sleep(:infinity)
    else
      case OrderInbox.run(client, journal, root) do
        {:ok, results} ->
          Enum.each(results, fn {key, result} ->
            status =
              case result do
                {:ok, receipt} -> receipt["outcome"]
                {:error, _} -> "pending; retry after checking the journal and Dropbox"
              end

            Mix.shell().info("#{key}: #{status}")
          end)

          if Enum.any?(results, fn {_, result} -> match?({:error, _}, result) end),
            do: Mix.raise("Some files are still pending")

        {:error, _} ->
          Mix.raise("Could not list the inbox")
      end
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
end
