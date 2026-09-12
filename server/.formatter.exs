[
  import_deps: [:phoenix, :ecto, :ecto_sql, :phoenix_live_view, :open_api_spex],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "*.{heex,ex,exs}",
    "{config,lib,test}/**/*.{heex,ex,exs}",
    "priv/*/seeds.exs"
  ]
]
