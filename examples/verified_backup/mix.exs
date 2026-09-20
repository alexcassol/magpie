defmodule VerifiedBackup.MixProject do
  use Mix.Project

  def project do
    [
      app: :verified_backup,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: [{:magpie, path: "../.."}, {:jason, "~> 1.4"}, {:plug, "~> 1.15", only: :test}]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
