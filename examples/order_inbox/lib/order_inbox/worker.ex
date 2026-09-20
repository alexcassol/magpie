defmodule OrderInbox.Worker do
  @moduledoc "Runs one scan at a time. The journal holds work that must survive a restart."
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    send(self(), :scan)
    {:ok, opts}
  end

  @impl true
  def handle_info(:scan, opts) do
    case OrderInbox.run(
           Keyword.fetch!(opts, :client),
           Keyword.fetch!(opts, :journal),
           Keyword.fetch!(opts, :root)
         ) do
      {:ok, results} ->
        failures = Enum.count(results, fn {_, result} -> match?({:error, _}, result) end)
        Logger.info("Inbox scan: #{length(results)} files, #{failures} pending failures")

      {:error, _} ->
        Logger.warning("Inbox listing failed; the next scan will retry")
    end

    Process.send_after(self(), :scan, Keyword.get(opts, :interval, 30_000))
    {:noreply, opts}
  end
end
