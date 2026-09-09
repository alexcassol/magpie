defmodule Magpie.MixProject do
  use Mix.Project

  @version "0.6.2"
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
    [extra_applications: [:logger, :telemetry]]
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
      {:req, "~> 0.7.4"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
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
        "guides/examples.md",
        "guides/oauth.md",
        "guides/phoenix.md",
        "guides/upgrading.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/
      ],
      groups_for_modules: [
        Core: [
          Magpie,
          Magpie.BatchError,
          Magpie.Client,
          Magpie.Error,
          Magpie.IntegrityError,
          Magpie.Storage,
          Magpie.Telemetry,
          Magpie.Utils
        ],
        "OAuth & tokens": [
          Magpie.Auth,
          Magpie.Auth.Token,
          Magpie.Auth.TokenProvider,
          Magpie.Auth.TokenServer,
          Magpie.Auth.StaticToken
        ],
        "High-level flows": [Magpie.Async, Magpie.Pager],
        Phoenix: [Magpie.LiveView, Magpie.LiveView.UploadWriter],
        Metadata: [
          Magpie.Metadata,
          Magpie.FileMetadata,
          Magpie.FolderMetadata,
          Magpie.DeletedMetadata
        ],
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
      links: %{"GitHub" => @source_url},
      # Hex's default file list leaves `guides/` out, so the package shipped
      # without the very files the README links to.
      files: ~w(lib priv guides mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end
end
