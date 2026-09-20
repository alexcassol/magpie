defmodule Mix.Tasks.Backup do
  use Mix.Task
  @shortdoc "Create, restore, or plan retention for verified Dropbox snapshots"

  def run(args) do
    Mix.Task.run("app.start")
    client = client()

    result =
      case args do
        ["create", source] ->
          VerifiedBackup.create(client, source)

        ["create", source, root] ->
          VerifiedBackup.create(client, source, root)

        ["restore", manifest, destination] ->
          VerifiedBackup.restore_from(client, manifest, destination)

        ["retention", root, keep] ->
          case Integer.parse(keep) do
            {n, ""} when n >= 1 -> VerifiedBackup.retention(client, root, n)
            _ -> Mix.raise("Keep at least one snapshot.")
          end

        _ ->
          Mix.raise(
            "Usage: mix backup create SOURCE [ROOT] | restore MANIFEST DESTINATION | retention ROOT KEEP"
          )
      end

    case result do
      {:ok, value} -> Mix.shell().info(inspect(value, pretty: true))
      {:error, reason} -> Mix.raise("Backup failed: #{inspect(reason)}")
    end
  end

  defp client do
    if refresh = System.get_env("DROPBOX_REFRESH_TOKEN") do
      Magpie.Client.new(
        refresh_token: refresh,
        app_key: System.fetch_env!("DROPBOX_APP_KEY"),
        app_secret: System.fetch_env!("DROPBOX_APP_SECRET"),
        timeout: 300_000
      )
    else
      Magpie.Client.new(System.fetch_env!("DROPBOX_ACCESS_TOKEN"), timeout: 300_000)
    end
  end
end
