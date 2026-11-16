#!/usr/bin/env bash
# Scripted assertions for poll.sh's single-repo mode (poll.sh <name>).
set -uo pipefail
cd "$(dirname "$0")/.."

SCRATCH=$(mktemp -d)
export HARBOR_DIR="$SCRATCH"
fail=0

cat > "$SCRATCH/config.json" <<EOF
{"interval_seconds":60,"repos":[
  {"name":"repo-a","path":"$SCRATCH/not-a-real-repo"},
  {"name":"repo-b","path":"$SCRATCH/not-a-real-repo"}
]}
EOF

cat > "$SCRATCH/status.json" <<'EOF'
{"generated_at":"2026-01-01T00:00:00Z","repos":[
  {"name":"repo-a","platform":"gitlab","branch":"main","state":"ok","label":"OK","url":"https://example.com/a","updated_at":"2026-01-01T00:00:00Z","fetched_at":"2026-01-01T00:00:00Z"},
  {"name":"repo-b","platform":"gitlab","branch":"main","state":"ok","label":"OK","url":"https://example.com/b","updated_at":"2026-01-01T00:00:00Z","fetched_at":"2026-01-01T00:00:00Z"}
]}
EOF

before=$(cat "$SCRATCH/status.json")

# Case 1: an invalid/unreachable path must be a safe no-op, not a crash or
# a clobber of good existing data with a synthetic "stale" entry — matches
# the original full-loop's "continue" behavior (skip silently).
bin/poll.sh repo-a > /dev/null 2>&1
after=$(cat "$SCRATCH/status.json")
if [ "$before" = "$after" ]; then
  echo "ok: invalid path leaves status.json completely untouched (no corruption, no clobber)"
else
  echo "FAIL: status.json changed from an unreachable repo's refresh, expected no-op"
  echo "before: $before"
  echo "after:  $after"
  fail=1
fi

# Case 2: a repo name not present in config at all exits cleanly, no crash.
if bin/poll.sh nonexistent-repo > /dev/null 2>&1; then
  echo "FAIL: expected a nonzero exit for a repo name missing from config"
  fail=1
else
  echo "ok: a repo name missing from config exits nonzero without touching status.json"
fi
after2=$(cat "$SCRATCH/status.json")
if [ "$before" != "$after2" ]; then
  echo "FAIL: status.json changed from a lookup for a nonexistent repo"
  fail=1
fi

# Case 3: the actual risky part — the in-place merge-by-name jq expression
# poll.sh uses to apply a real fetched entry. Tested directly (not through
# a real network fetch, which would be flaky/need auth in CI) to confirm it
# replaces only the targeted repo and preserves array order.
new_entry='{"name":"repo-a","platform":"gitlab","branch":"main","state":"failed","label":"Failed","url":"https://example.com/a2","updated_at":"2026-02-01T00:00:00Z","fetched_at":"2026-02-01T00:00:05Z"}'
jq --arg name "repo-a" --argjson e "$new_entry" --arg generated_at "2026-02-01T00:00:05Z" '
  .generated_at = $generated_at |
  .repos |= map(if .name == $name then $e else . end)
' "$SCRATCH/status.json" > "$SCRATCH/status.json.merged"

merged_state=$(jq -r '.repos[] | select(.name=="repo-a") | .state' "$SCRATCH/status.json.merged")
merged_b_url=$(jq -r '.repos[] | select(.name=="repo-b") | .url' "$SCRATCH/status.json.merged")
merged_order=$(jq -r '.repos[].name' "$SCRATCH/status.json.merged" | tr '\n' ',')

if [ "$merged_state" = "failed" ]; then
  echo "ok: merge jq replaces the targeted repo's entry"
else
  echo "FAIL: expected repo-a state=failed after merge, got $merged_state"
  fail=1
fi
if [ "$merged_b_url" = "https://example.com/b" ]; then
  echo "ok: merge jq leaves the other repo's entry untouched"
else
  echo "FAIL: merge jq modified repo-b, expected untouched"
  fail=1
fi
if [ "$merged_order" = "repo-a,repo-b," ]; then
  echo "ok: merge jq preserves repo order"
else
  echo "FAIL: expected order repo-a,repo-b, got $merged_order"
  fail=1
fi

/bin/rm -rf "$SCRATCH"
exit $fail
