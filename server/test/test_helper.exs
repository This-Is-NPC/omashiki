# Load test-only secrets from server/.env if present. The file is gitignored
# and only consumed by tests (nothing reads it at runtime). Real CI can set
# the same vars directly; already-set vars are preserved.
Omashiki.Test.Dotenv.load(Path.expand("../.env", __DIR__))

# Exclude integration tests that spin up real Docker containers + hit a real
# LLM providers. Run them explicitly with `mix test --only real_opencode`,
# `mix test --only real_claude`, or `mix test --only real_jcode`.
ExUnit.start(exclude: [:real_opencode, :real_claude, :real_jcode, :ollama, :real_container])

# Pin the node this suite runs as. `Config.current_machine/0` otherwise falls back
# to the developer's hostname, which would make `execution_capacity` — now keyed
# by `node_id` — belong to a different node on every machine the suite runs on.
# `"local"` is the name the schema migration gives the row it ships, so the
# default node and the migrated row are the same node everywhere.
System.put_env("OMASHIKI_NODE", "local")

Ecto.Adapters.SQL.Sandbox.mode(Omashiki.Repo, :manual)
