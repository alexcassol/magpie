defmodule Magpie.MixProject do
  use Mix.Project

  @version "0.2.1"
  @source_url "https://github.com/alexcassol/magpie"

  def project do
    [
      app: :magpie,
      version: @version,
      elixir: "~> 1.15",
      name: "Magpie",
      description: "Elixir client for the Dropbox API v2, built on Req",
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls],
      package: package(),
      docs: docs(),
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.github": :test
      ]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.7"},
      {:plug, "~> 1.15", only: :test},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "guides/oauth.md",
        "guides/examples.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/
      ],
      groups_for_modules: [
        Core: [Magpie, Magpie.Client, Magpie.Error, Magpie.Utils],
        "OAuth & tokens": [
          Magpie.Auth,
          Magpie.Auth.Token,
          Magpie.Auth.TokenProvider,
          Magpie.Auth.TokenServer,
          Magpie.Auth.StaticToken
        ],
        "High-level flows": [Magpie.Async, Magpie.Pager],
        Files: ~r/Magpie\.Files.*/,
        Sharing: [Magpie.Sharing],
        "Users & Account": [
          Magpie.Users,
          Magpie.Accounts,
          Magpie.Check,
          Magpie.Contacts,
          Magpie.OpenId
        ],
        "File properties & requests": [Magpie.FileProperties, Magpie.FileRequests],
        "Paper (deprecated)": ~r/Magpie\.Paper.*/,
        Structs: [
          Magpie.Account,
          Magpie.Allocation,
          Magpie.Folder,
          Magpie.Name,
          Magpie.SharedLink,
          Magpie.SpaceUsage
        ]
      ]
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
