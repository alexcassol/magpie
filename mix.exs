defmodule Magpie.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/alexcassol/magpie"

  def project do
    [
      app: :magpie,
      version: @version,
      elixir: "~> 1.15",
      name: "Magpie",
      description: "Elixir client for the Dropbox API v2, built on Req",
      start_permanent: Mix.env() == :prod,
      package: package(),
      docs: docs(),
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:req, "~> 0.7"},
      {:plug, "~> 1.15", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md", "LICENSE"]
    ]
  end

  defp package do
    [
      maintainers: ["Alex Cassol"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
