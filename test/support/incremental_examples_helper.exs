defmodule MagpieGuide.TestStore do
  # A process-local fake for checking the application contract, not a production lease.
  def with_account_lease(account, fun) do
    Process.put(:guide_lease, account)
    send(self(), :lease_acquired)

    try do
      fun.()
    after
      Process.delete(:guide_lease)
      send(self(), :lease_released)
    end
  end

  def root(account) do
    assert_lease(account)
    ""
  end

  def cursor(account) do
    assert_lease(account)

    case Process.get(:guide_live) do
      %Magpie.ListPage{cursor: cursor} -> cursor
      {_, cursor} -> cursor
      nil -> nil
    end
  end

  def assert_lease(account) do
    if Process.get(:guide_lease) != account, do: raise("account lease is required")
  end

  def apply_page_and_checkpoint(_account, page) do
    Process.put(:guide_live, page)
    :ok
  end

  def begin_shadow(_account) do
    Process.put(:guide_shadow, [])
    :shadow
  end

  def apply_shadow_page(:shadow, page) do
    Process.put(:guide_shadow, Process.get(:guide_shadow) ++ page.entries)
    :ok
  end

  def publish_shadow(_account, :shadow, final) do
    Process.put(:guide_live, {Process.get(:guide_shadow), final})
    :ok
  end

  def discard_shadow(:shadow), do: Process.delete(:guide_shadow)
end

defmodule MagpieGuide.TestClients do
  def for_account(account) do
    MagpieGuide.TestStore.assert_lease(account)
    Magpie.Client.new("fake")
  end
end

defmodule MagpieGuide.TestJobs do
  def app_secret, do: "fake-app-secret"

  def enqueue(accounts) do
    send(self(), {:enqueue, accounts})
    :ok
  end
end

defmodule MagpieGuide.Examples do
  @moduledoc false
  @guide Path.expand("../../guides/incremental.md", __DIR__)
  @readme Path.expand("../../README.md", __DIR__)

  def block(name) do
    content = if name == "incremental", do: File.read!(@readme), else: File.read!(@guide)

    [code] =
      Regex.run(~r/<!-- executable-#{name} -->\s*```elixir\n(.*?)\n```/s, content,
        capture: :all_but_first
      )

    code
  end

  def module_block(name) do
    [code] =
      Regex.run(
        ~r/```elixir\n(defmodule MyApp\.#{name}.*?end)\n```/s,
        File.read!(@guide),
        capture: :all_but_first
      )

    code
  end

  def compile(code) do
    code
    |> String.replace("MyApp.Store", "MagpieGuide.TestStore")
    |> String.replace("MyApp.DropboxClients", "MagpieGuide.TestClients")
    |> String.replace("MyApp.DropboxJobs", "MagpieGuide.TestJobs")
    |> String.replace("MyApp.DropboxRecovery", "MagpieGuide.TestRecovery")
    |> String.replace("MyApp.DropboxScan", "MagpieGuide.TestScan")
    |> String.replace("MyApp.DropboxEndpoint", "MagpieGuide.TestEndpoint")
    |> String.replace("MyApp.DropboxConsumerTest", "MagpieGuide.ConsumerTest")
    |> Code.compile_string("guides/incremental.md")
  end
end

MagpieGuide.Examples.compile(MagpieGuide.Examples.block("scanner"))
MagpieGuide.Examples.compile(MagpieGuide.Examples.module_block("DropboxRecovery"))
MagpieGuide.Examples.compile(MagpieGuide.Examples.module_block("DropboxScan"))
MagpieGuide.Examples.compile(MagpieGuide.Examples.block("endpoint"))
MagpieGuide.Examples.compile(MagpieGuide.Examples.block("consumer-test"))
