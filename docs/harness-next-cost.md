# Harness next-cost measurement (task 2826)

Measured at commit on `task/2826` after extracting `Omashiki.Harness.CliJson`.
Baseline for comparison: task 2821 (`pi` harness) six cost centres.

## Line counts after extraction

| Module | Before (6fe607e) | After |
| --- | ---: | ---: |
| `cli_json.ex` | — | 213 |
| `jcode.ex` | 233 | 138 |
| `pi.ex` | 298 | 204 |
| `codex.ex` | 277 | 210 |
| `claude_code.ex` | 284 | 214 |
| `open_code.ex` | 281 | 281 (unchanged) |
| `open_code_http.ex` | 319 | 319 (unchanged) |

Four CLI adapters + shared base: **979 lines** (was **1,092** across the four adapters alone).

## What stayed out of the base

- **`open_code_http.ex`** — second transport (`kind=http`, SSE session lifecycle, startup/readiness). The `CliJson` base fits exec-and-parse-stdout only; HTTP harnesses keep their own module.
- **`claude_code.ex` / `codex.ex` host checks** — `require_mount/2`, `expand_host_path/1`, and `File.regular?` credential verification remain in each adapter (security decisions, not templating).
- **`open_code.ex`** — HTTP/gateway hybrid with its own prepare/invoke path; not folded into `CliJson`.

## Six-centre comparison vs 2821 (`pi`)

| Centre | 2821 (`pi`, pre-base) | Next gateway CLI harness (post-base, estimated) | Remains? |
| --- | --- | --- | --- |
| Adapter module | ~298 lines (full module) | ~95–110 lines: `validate_options` + `launch_plan` + `cli_argv` + `decode_output` + `normalize_result` + constants; invoke/prepare delegate to `CliJson` | Yes, but ~65% smaller |
| Docker image | `agent/Dockerfile.pi` (~100 lines) | Same class of work — tool binary, runner script, mise/OTP if needed | Yes |
| Registry entry | `omashiki.toml` `[harnesses.pi]` + `[environments.pi]` | One harness stanza + environment block | Yes |
| CI wiring | `mix.exs` `ci:docker` target, arch-check allowlist | Per-harness docker build + CI alias | Yes |
| Tests | `pi_test.exs` 181 lines | ~80–120 lines focused on decode shape, usage keys, launch_plan | Yes, smaller |
| Merge cycle | Review + cherry-pick to master | Unchanged | Yes |

**Estimated next harness total:** ~95–110 adapter + ~100 docker + ~15 registry + ~10 CI + ~100 tests ≈ **320–335 lines** of authored material, of which **~40–55 lines are the decode shape and usage key map** (the only part that differs materially from a sibling gateway harness like `jcode`).

## Gate verdict: **manifest closed**

Wave 2 does not start. After `CliJson`, the adapter centre that a declarative manifest would eliminate is already reduced to a thin shell: constants, option validation, `launch_plan`/`cli_argv`, and two callbacks (`decode_output`, `normalize_result`). The measured delta between `jcode` (138 lines) and `pi` (204 lines) is **66 lines**, almost entirely stream-decode folding (`sum_usage`, `assistant_text`) and pi-specific environment — i.e. decode shape plus usage key map. The other five 2821 centres (image, registry, CI, tests, merge) are untouched by either a manifest or this extraction. Building a manifest format to avoid ~100 lines of adapter data would not pay for itself against the remaining ~220 lines of non-adapter work per harness.

## Doc vocabulary gap

Nine existing `docs/` files still teach pre-plugin vocabulary. This measurement does not rewrite them; `plugins-e-ciclo-de-vida.md` is the canonical design-direction source for the plugin phase.
