defmodule HashAnchoredPatch.MixProject do
  use Mix.Project

  def project do
    [
      app: :hash_anchored_patch,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Hash-anchored surgical file patching for Elixir, with an optional LLM-driven editor.",
      package: package(),
      source_url: "https://github.com/emilsoman/hash_anchored_patch"
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/emilsoman/hash_anchored_patch"},
      files: ~w(lib priv .formatter.exs mix.exs README.md)
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
      {:baml_elixir, "~> 1.0.0-pre.27"}
    ]
  end
end
