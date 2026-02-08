defmodule A2aEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :a2a_ex,
      version: "0.1.1",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      description: "Elixir client and server library for the Agent2Agent protocol.",
      package: package(),
      source_url: "https://github.com/lukaszsamson/a2a_ex",
      docs: docs(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.15"},
      {:plug_cowboy, "~> 2.7", only: :test},
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.2"}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/lukaszsamson/a2a_ex",
        "Changelog" => "https://github.com/lukaszsamson/a2a_ex/blob/main/CHANGELOG.md"
      },
      maintainers: ["Łukasz Samson"],
      files: ["lib", "mix.exs", "README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end

  defp docs do
    [
      main: "A2A",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
