# CI Baseline

Reference point for the local CI matrix. Every later change that claims "CI is
still green" compares against this record. Re-take it — do not edit it in place —
when the matrix itself changes shape, and record the new commit alongside the old.

**Baseline commit:** `c1bfa3b8dfdd604d4102f8861b509772c69b0794`
(`ci(docker): gate the jcode agent image build`)
**Taken:** 2026-08-26
**Tree state:** clean — `git status --porcelain` produced no output before and
after the run
**Host:** single developer workstation, Linux 7.1.9-arch1-2, `max_cases: 24`
(24 scheduler-visible cores). Postgres in `server-db-1` on port 5442.

Every target below was judged by its **exit code**, never by its output text.
Two of these targets print alarming text and exit `0`; see the notes.

## Matrix

| target | command | exit | headline |
|---|---|---:|---|
| server, run 1 | `mise run ci:server` | 0 | 413 tests, 0 failures, 2 excluded — 15.1s (0.9s async, 14.2s sync), seed 747880 |
| server, run 2 | `MIX_ENV=test mix test --seed 0` | 0 | 413 tests, 0 failures, 2 excluded — 15.4s (0.7s async, 14.7s sync), seed 0 |
| assets | `mise run ci:server:assets` | 0 | tailwind 254ms; esbuild 16ms, `app.js` 329.7kb |
| vuln | `mise run ci:server:vuln` | 0 | 3 cowlib advisories, all under `Ignored advisories:` |
| cover | `mise run ci:server:cover` | 0 | 413 tests, 0 failures, 3 excluded — total coverage **56.96%**, seed 188598 |
| docker | `mise run ci:docker` | 0 | 5 images built (warm layer cache) |
| architecture | `.scripts/arch_check.sh` (no `--fast`) | 0 | 11/11 static invariants PASS, 0 active exceptions |
| format | `mix format --check-formatted` | 0 | clean |

No target failed, so no "last 10 lines on failure" blocks are recorded.

### Test counts

`413 tests` is the total collected in every run; only the excluded count moves.
`test/test_helper.exs` always excludes `:real_opencode`, `:real_claude`,
`:ollama`, and `:real_container` — that is the `2 excluded` in the full run.
`ci:server:fast` and `ci:server:cover` add `--exclude integration`, which moves
exactly **one** further test, giving `3 excluded`. The practical delta between
the "fast" and "full" suites is therefore a single test.

### Two-seed comparison

Run 1 (seed 747880) and run 2 (seed 0) are identical: 413 tests, 0 failures.
`claims_test` and `runner_test`, previously observed as timing-flaky under heavy
machine load, were **stable under both orderings on an otherwise idle host**.
Their earlier failures are attributable to load, not to order dependence and not
to a defect. Re-check them specifically after any load-generating change.

### Docker image sizes (Wave 2 "before" numbers)

Measured with `docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}'`.

| image | size |
|---|---:|
| `omashiki/agent:latest` / `:ci-check` | 7.21 GB |
| `omashiki/agent-claude:latest` / `:ci-check` | 8.41 GB |
| `omashiki/agent-codex:latest` / `:ci-check` | 8.46 GB |
| `omashiki/agent-jcode:latest` / `:ci-check` | 484 MB |
| `omashiki/server:ci-check` | 85.3 MB |

`omashiki/agent-arch` also exists locally (7.21-7.34 GB) but is not produced by
`ci:docker`. Build times on a warm cache: jcode 1.62s, codex 1.90s, claude
33.15s, server 61.06s, agent 93.98s.

The agent images are dominated by the `ghcr.io/omacom-io/omaterm` base, roughly
6.47 GB of `omashiki/agent`'s 7.21 GB. jcode's 484 MB is what an agent image
costs without that base.

The table above is a "before" record and is deliberately left at its measured
values. That base has since been dropped: `agent`, `agent-claude` and
`agent-codex` were rebased on `debian:13-slim` and now measure 699 MB, 1.1 GB
and 1.09 GB. `ci:docker` asserts a budget so the regression cannot return
silently.

## Standing items this baseline exposes

These are recorded observations, not regressions introduced by the baseline
commit. Nothing here was fixed while taking the measurement.

### The cowlib ignore list has no review date

`server/mix.exs` suppresses three advisories:

    hex: [ignore_advisories: ["EEF-CVE-2026-43966", "EEF-CVE-2026-43969", "EEF-CVE-2026-43971"]]

The suppression is justified — cowlib arrives only through the test-only Bypass
server, and the findings sit in response encoders Omashiki never calls — and it
is why `ci:server:vuln` exits `0` despite printing three CVEs. But the list
carries no review date and no removal condition, so it will outlive its
justification silently. It should be re-checked whenever the `bypass` dependency
moves, and dropped as soon as cowlib ships a fixed release.

`ci:server:vuln` also prints a TLS handshake failure against `builds.hex.pm`
(`key_usage_mismatch`) before the audit result. That is the Hex *version check*,
not the audit, and it does not affect the exit code.

### INV5 and INV7 are not enforced anywhere

`.scripts/arch_check.sh` without `--fast` claims to run "Reflection checks
(ExUnit) — INV5 vocabulary, INV7 orphan behaviour". It does not. The block is
guarded by `[ -f "$SRV/test/omashiki/architecture_test.exs" ]`, that file does
not exist, and the `else` branch prints a green `PASS` reading "INV5/INV7
reflection suite not applicable: no active queue-only reflection test exists
after legacy-domain deletion".

`--fast` meanwhile prints "INV5 and INV7 run in the mix test suite, not here",
which is also untrue: a repository-wide search for `INV5`/`INV7` outside
`arch_check.sh` finds nothing. Both invariants have **zero enforcement**, and
both paths through the gate report success. The 11 static invariants that do run
(INV1-INV4, INV6, INV8-INV13) are genuinely checked.

### `ci:server:assets` mutates a tracked file

Running `mise run ci:server:assets` on a clean tree leaves
`server/priv/static/assets/app.js` modified. The committed copy carries an inline
base64 source map; the test-env esbuild profile in `server/config/config.exs`
does not pass `--sourcemap=inline`, so the target regenerates the bundle without
it and deletes that line.

Only the dev watcher passes that flag (`server/config/dev.exs`:
`esbuild: {Esbuild, :install_and_run, [:omashiki, ~w(--sourcemap=inline --watch)]}`),
so the committed artifact is a dev-watcher output that no build target — neither
`assets.build` nor `assets.deploy` — reproduces. Consequences: the asset CI
target cannot run on a clean tree without dirtying it, a `git diff --exit-code`
gate after asset build would fail, and a production static asset ships an inline
map of development sources.

### The gateway is untested

`Omashiki.Gateway`, `Omashiki.Gateway.Budget`, `Omashiki.Gateway.Provider`,
`Omashiki.Gateway.Providers.AnthropicNative`, and
`Omashiki.Gateway.Providers.OpenaiCompat` all report **0.00%** coverage. This is
the same subsystem where a missing router entry once let jobs report `succeeded`
having made zero LLM calls. Coverage is reported and never enforced
(`test_coverage: [summary: [threshold: 0]]`), so nothing flags this.
