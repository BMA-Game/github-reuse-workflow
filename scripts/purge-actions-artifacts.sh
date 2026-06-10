#!/usr/bin/env bash
# One-time purge of GitHub Actions artifacts across BMA workspace repos.
# Default: dry-run (list only). Pass --confirm to delete.
set -euo pipefail

ORG="BMA-Game"
WORKSPACE_ROOT="${BMA_WORKSPACE_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
CONFIRM=false
FILTER_REPO=""
LIST_REPOS=false
JOBS=4
VERBOSE=false
NO_PROGRESS=false

usage() {
  cat <<'EOF'
Usage: purge-actions-artifacts.sh [--confirm] [--repo <name>] [--list-repos] [--jobs N] [--verbose] [--no-progress]

  --confirm       Delete artifacts (default is dry-run only)
  --repo <name>   Limit to a single BMA-Game repo name
  --list-repos    Print discovered repos and exit (no API calls)
  --jobs N        Process up to N repos in parallel (default: 4)
  --verbose       Print per-artifact details (default: quiet one-liner per repo)
  --no-progress   Disable live progress bar
  -h, --help      Show this help

Environment:
  BMA_WORKSPACE_ROOT  Workspace root (default: auto-detected from script location)

Requires: gh, jq. gh must be authenticated with repo + actions:write scopes.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM=true; shift ;;
    --repo) FILTER_REPO="${2:?--repo requires a value}"; shift 2 ;;
    --list-repos) LIST_REPOS=true; shift ;;
    --jobs) JOBS="${2:?--jobs requires a value}"; shift 2 ;;
    --verbose) VERBOSE=true; shift ;;
    --no-progress) NO_PROGRESS=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: --jobs must be a positive integer (got: $JOBS)" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq not found" >&2
  exit 1
fi

discover_repos() {
  local dir remote name
  for base in backends frontends infrastructure; do
    [[ -d "$WORKSPACE_ROOT/$base" ]] || continue
    for dir in "$WORKSPACE_ROOT/$base"/*/; do
      [[ -d "$dir/.git" ]] || continue
      remote=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
      [[ -n "$remote" ]] || continue
      name=$(echo "$remote" | sed -E 's#.*[:/]BMA-Game/([^/.]+)(\.git)?$#\1#')
      [[ -n "$name" && "$name" != "$remote" ]] || continue
      echo "$name"
    done
  done | sort -u
}

format_bytes() {
  local bytes=$1
  if (( bytes >= 1073741824 )); then
    printf "%.2f GiB" "$(awk "BEGIN { printf \"%.2f\", $bytes / 1073741824 }")"
  elif (( bytes >= 1048576 )); then
    printf "%.2f MiB" "$(awk "BEGIN { printf \"%.2f\", $bytes / 1048576 }")"
  elif (( bytes >= 1024 )); then
    printf "%.2f KiB" "$(awk "BEGIN { printf \"%.2f\", $bytes / 1024 }")"
  else
    printf "%d B" "$bytes"
  fi
}

list_artifacts() {
  local repo=$1 page=1 response
  while true; do
    response=$(gh api "repos/${ORG}/${repo}/actions/artifacts?per_page=100&page=${page}" 2>&1) || {
      if echo "$response" | grep -q 'Not Found'; then
        echo "WARN: ${ORG}/${repo} — repo not found or Actions disabled" >&2
        return 0
      fi
      echo "ERROR: ${ORG}/${repo} — failed to list artifacts: $response" >&2
      return 1
    }
    echo "$response" | jq -r '.artifacts[] | "\(.id)\t\(.name)\t\(.size_in_bytes)\t\(.created_at)"'
    local count
    count=$(echo "$response" | jq '.artifacts | length')
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done
}

delete_artifact() {
  local repo=$1 id=$2
  gh api --method DELETE "repos/${ORG}/${repo}/actions/artifacts/${id}" >/dev/null 2>&1
}

increment_progress() {
  flock "$RUN_DIR/progress.lock" bash -c '
    n=0
    [[ -f "'"$RUN_DIR"'/progress" ]] && n=$(<"'"$RUN_DIR"'/progress")
    echo $((n + 1)) > "'"$RUN_DIR"'/progress"
  '
}

list_repo_manifest() {
  local repo=$1
  local manifest="$RUN_DIR/$repo.manifest"
  if ! list_artifacts "$repo" > "$manifest"; then
    echo 1 > "$RUN_DIR/$repo.list_failed"
    : > "$manifest"
  else
    echo 0 > "$RUN_DIR/$repo.list_failed"
  fi
  touch "$RUN_DIR/$repo.list_done"
}

process_repo_manifest() {
  local repo=$1
  local manifest="$RUN_DIR/$repo.manifest"
  local log_file="$RUN_DIR/$repo.log"
  local stats_file="$RUN_DIR/$repo.stats"
  local exit_file="$RUN_DIR/$repo.exit"
  local repo_artifacts=0 repo_bytes=0 repo_failed=0
  local lines=()

  touch "$RUN_DIR/$repo.phase2"

  if [[ ! -s "$manifest" ]]; then
    printf '%s\t%s\t%s\t%s\n' 0 0 0 0 > "$stats_file"
    echo 0 > "$exit_file"
    touch "$RUN_DIR/$repo.done"
    return 0
  fi

  mapfile -t lines < "$manifest"

  {
    if [[ "$VERBOSE" == true ]]; then
      echo "=== ${ORG}/${repo} (${#lines[@]} artifacts) ==="
    fi

    for line in "${lines[@]}"; do
      IFS=$'\t' read -r id name size created <<< "$line"
      repo_artifacts=$((repo_artifacts + 1))
      repo_bytes=$((repo_bytes + size))

      if [[ "$VERBOSE" == true ]]; then
        echo "  id=$id  name=$name  size=$(format_bytes "$size")  created=$created"
      fi

      if [[ "$CONFIRM" == true ]]; then
        if delete_artifact "$repo" "$id"; then
          :
        else
          echo "  ERROR: ${ORG}/${repo} failed to delete artifact $id" >&2
          repo_failed=$((repo_failed + 1))
        fi
      fi

      increment_progress
    done

    if [[ "$CONFIRM" == true ]]; then
      local deleted=$((repo_artifacts - repo_failed))
      echo "${ORG}/${repo}: deleted ${deleted}/${repo_artifacts} ($(format_bytes "$repo_bytes"))"
    else
      echo "${ORG}/${repo}: would delete ${repo_artifacts} artifacts ($(format_bytes "$repo_bytes"))"
    fi
  } > "$log_file"

  printf '%s\t%s\t%s\t%s\n' "$repo_artifacts" "$repo_bytes" "$repo_failed" 0 > "$stats_file"
  if [[ "$repo_failed" -gt 0 ]]; then
    echo 1 > "$exit_file"
  else
    echo 0 > "$exit_file"
  fi
  touch "$RUN_DIR/$repo.done"
}

get_active_repos() {
  local repo active=() f
  shopt -s nullglob
  for f in "$RUN_DIR"/*.phase2; do
    repo=$(basename "$f" .phase2)
    [[ -f "$RUN_DIR/$repo.done" ]] && continue
    active+=("$repo")
  done
  shopt -u nullglob
  if [[ ${#active[@]} -gt 0 ]]; then
    local joined
    joined=$(IFS=,; echo "${active[*]}")
    printf '  active: %s' "$joined"
  fi
}

render_progress_bar() {
  local done=$1 total=$2 width=40
  local pct=0 filled=0 empty=$width active
  if (( total > 0 )); then
    pct=$((done * 100 / total))
    filled=$((done * width / total))
    empty=$((width - filled))
  fi
  active=$(get_active_repos)
  printf '\r[%*s>%*s] %d/%d (%d%%)%s' "$filled" '' "$empty" '' "$done" "$total" "$pct" "$active"
}

watch_progress() {
  local total=$1
  local done=0 last_non_tty=0
  while [[ -f "$RUN_DIR/phase2.running" ]]; do
    done=$(<"$RUN_DIR/progress" 2>/dev/null || echo 0)
    if [[ "$PROGRESS_TTY" == true ]]; then
      render_progress_bar "$done" "$total" >&2
    elif [[ "$SHOW_PROGRESS" == true ]] && (( done - last_non_tty >= 100 || (total > 0 && done == total) )); then
      echo "Progress: ${done}/${total}" >&2
      last_non_tty=$done
    fi
    sleep 0.2
  done
  if [[ "$PROGRESS_TTY" == true ]]; then
    render_progress_bar "$total" "$total" >&2
    echo >&2
  fi
}

repos=()
if [[ -n "$FILTER_REPO" ]]; then
  repos=("$FILTER_REPO")
else
  mapfile -t repos < <(discover_repos)
fi

if [[ ${#repos[@]} -eq 0 ]]; then
  echo "error: no repos discovered under $WORKSPACE_ROOT" >&2
  exit 1
fi

if [[ "$LIST_REPOS" == true ]]; then
  printf '%s\n' "${repos[@]}"
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI not found" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "error: gh is not authenticated (run: gh auth login)" >&2
  exit 1
fi

SHOW_PROGRESS=false
PROGRESS_TTY=false
if [[ "$NO_PROGRESS" == false ]]; then
  SHOW_PROGRESS=true
  [[ -t 2 ]] && PROGRESS_TTY=true
fi

echo "Workspace: $WORKSPACE_ROOT"
echo "Org:       $ORG"
echo "Repos:     ${#repos[@]}"
echo "Jobs:      $JOBS"
echo "Mode:      $([[ "$CONFIRM" == true ]] && echo DELETE || echo DRY-RUN)"
echo

RUN_DIR=$(mktemp -d)
trap 'rm -rf "$RUN_DIR"' EXIT

export ORG CONFIRM RUN_DIR VERBOSE SHOW_PROGRESS PROGRESS_TTY
export -f format_bytes list_artifacts delete_artifact increment_progress list_repo_manifest process_repo_manifest

echo "Phase 1: listing artifacts..."
printf '%s\0' "${repos[@]}" | xargs -0 -P "$JOBS" -n 1 bash -c 'list_repo_manifest "$1"' _

TOTAL_ARTIFACTS=0
REPOS_WITH_ARTIFACTS=0
failed_lists=0

for repo in "${repos[@]}"; do
  if [[ -f "$RUN_DIR/$repo.list_failed" && "$(<"$RUN_DIR/$repo.list_failed")" == "1" ]]; then
    failed_lists=$((failed_lists + 1))
    continue
  fi
  if [[ -f "$RUN_DIR/$repo.manifest" ]] && [[ -s "$RUN_DIR/$repo.manifest" ]]; then
    count=$(wc -l < "$RUN_DIR/$repo.manifest")
    TOTAL_ARTIFACTS=$((TOTAL_ARTIFACTS + count))
    REPOS_WITH_ARTIFACTS=$((REPOS_WITH_ARTIFACTS + 1))
  fi
done

phase2_repos=()
for repo in "${repos[@]}"; do
  if [[ -f "$RUN_DIR/$repo.manifest" ]] && [[ -s "$RUN_DIR/$repo.manifest" ]]; then
    phase2_repos+=("$repo")
  fi
done

action_label=$([[ "$CONFIRM" == true ]] && echo DELETE || echo DRY-RUN)
echo "Listed ${TOTAL_ARTIFACTS} artifacts across ${REPOS_WITH_ARTIFACTS} repos. Starting ${action_label}..."

if [[ ${#phase2_repos[@]} -eq 0 ]]; then
  echo "No artifacts to process."
else
  echo 0 > "$RUN_DIR/progress"
  touch "$RUN_DIR/phase2.running"

  WATCHER_PID=""
  if [[ "$SHOW_PROGRESS" == true ]]; then
    watch_progress "$TOTAL_ARTIFACTS" &
    WATCHER_PID=$!
  fi

  printf '%s\0' "${phase2_repos[@]}" | xargs -0 -P "$JOBS" -n 1 bash -c 'process_repo_manifest "$1"' _

  rm -f "$RUN_DIR/phase2.running"
  if [[ -n "$WATCHER_PID" ]]; then
    wait "$WATCHER_PID" 2>/dev/null || true
  fi
fi

echo

total_artifacts=0
total_bytes=0
failed_deletes=0
any_worker_failed=0

for repo in "${repos[@]}"; do
  if [[ "$VERBOSE" == true || "$NO_PROGRESS" == true ]]; then
    if [[ -f "$RUN_DIR/$repo.log" ]]; then
      cat "$RUN_DIR/$repo.log"
      echo
    fi
  elif [[ -f "$RUN_DIR/$repo.log" ]]; then
    cat "$RUN_DIR/$repo.log"
  fi

  if [[ -f "$RUN_DIR/$repo.stats" ]]; then
    IFS=$'\t' read -r repo_artifacts repo_bytes repo_failed _failed_list < "$RUN_DIR/$repo.stats"
    total_artifacts=$((total_artifacts + repo_artifacts))
    total_bytes=$((total_bytes + repo_bytes))
    failed_deletes=$((failed_deletes + repo_failed))
  fi

  if [[ -f "$RUN_DIR/$repo.exit" && "$(<"$RUN_DIR/$repo.exit")" != "0" ]]; then
    any_worker_failed=1
  fi
done

echo "========== SUMMARY =========="
echo "Repos scanned:    ${#repos[@]}"
echo "Total artifacts:  $total_artifacts"
echo "Total size:       $(format_bytes "$total_bytes")"
if [[ "$CONFIRM" == true ]]; then
  echo "Failed deletes:   $failed_deletes"
else
  echo
  echo "Dry-run complete. Re-run with --confirm to delete."
fi
echo "Failed list calls: $failed_lists"

if [[ "$failed_deletes" -gt 0 || "$failed_lists" -gt 0 || "$any_worker_failed" -gt 0 ]]; then
  exit 1
fi
