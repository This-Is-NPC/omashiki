defmodule Omashiki.MixProject do
  use Mix.Project

  def project do
    [
      app: :omashiki,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      # Cowlib is pulled only by the test-only Bypass server. These findings
      # affect response encoders that Omashiki does not call in tests.
      hex: [
        ignore_advisories: [
          "EEF-CVE-2026-43966",
          "EEF-CVE-2026-43969",
          "EEF-CVE-2026-43971"
        ]
      ],
      releases: releases(),
      # Coverage is reported, never enforced — see CONTRIBUTING.md
      # "Test Suite Taxonomy". A real threshold belongs in a future plan
      # once the team agrees on a stable target.
      test_coverage: [summary: [threshold: 0]]
    ]
  end

  defp releases do
    [
      omashiki: [
        include_executables_for: [:unix],
        steps: [:assemble, :tar]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Omashiki.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  defp deps do
    [
      {:phoenix_pubsub, "~> 2.1"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22.4"},
      {:jason, "~> 1.2"},
      # Reads omashiki.toml at the repo root (see config/runtime.exs). Pure
      # Elixir, no NIF — runtime.exs must be able to parse it before boot.
      {:toml, "~> 0.7"},
      {:mint, "~> 1.9.3"},
      {:phoenix, "~> 1.8.12"},
      {:bypass, "~> 2.1", only: :test},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.10"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2.0", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.1.1",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:bandit, "~> 1.12.5"},
      {:argon2_elixir, "~> 4.0"},
      {:oban, "~> 2.19"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": [
        "tailwind omashiki",
        "esbuild omashiki",
        "omashiki.assets.copy_fonts"
      ],
      "assets.deploy": [
        "tailwind omashiki --minify",
        "esbuild omashiki --minify",
        "omashiki.assets.copy_fonts",
        "phx.digest"
      ]
    ]
  end
end
