defmodule DocumentSearch.MixProject do
  use Mix.Project

  def project do
    [
      app: :document_search,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: [
        {:magpie, path: "../.."},
        {:exqlite, "~> 0.40.0"},
        {:plug, "~> 1.15", only: :test}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
