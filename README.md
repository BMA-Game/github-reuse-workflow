# github-reuse-workflow

Reusable GitHub Actions workflows for BMA-Game services.

## Artifact retention policy

| Workflow | Artifact | Retention |
|---|---|---|
| `test.yaml` | `test-coverage` (on failure only) | 7 days |
| `frontend-export.yaml` | build `out/` handoff | 1 day |

New workflow runs auto-expire per `retention-days`. Artifacts created before this policy used GitHub's 90-day default and must be purged separately.

## One-time artifact purge

Prerequisites: `gh` and `jq`. `gh` must be authenticated with `repo` + `actions:write` scopes.

The purge script deletes **all** Actions artifacts in each targeted repo (no age or name filter). That includes legacy `out`, `test-coverage`, `*.dockerbuild`, and any other artifact type. Use `--repo` to limit scope.

While running on a TTY, a combined progress bar shows artifacts processed across all repos. Use `--no-progress` to disable it (e.g. CI or piping). Use `--verbose` for per-artifact details.

```bash
# List discovered repos (no API calls)
./scripts/purge-actions-artifacts.sh --list-repos

# Dry-run (default) — progress bar on stderr, one line per repo on stdout
./scripts/purge-actions-artifacts.sh

# Dry-run with more parallelism
./scripts/purge-actions-artifacts.sh --jobs 8

# Full per-artifact log
./scripts/purge-actions-artifacts.sh --verbose

# No live progress bar (logs at end)
./scripts/purge-actions-artifacts.sh --no-progress

# Pilot on one repo
./scripts/purge-actions-artifacts.sh --repo game-client --confirm

# Full purge
./scripts/purge-actions-artifacts.sh --confirm
```

Repos are discovered from git remotes under `backends/`, `frontends/`, and `infrastructure/` in the BMA workspace. Override the root with `BMA_WORKSPACE_ROOT` if needed.
