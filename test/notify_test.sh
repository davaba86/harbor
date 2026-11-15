#!/usr/bin/env bash
# Scripted assertions for bin/notify.sh's diff logic, using a scratch
# HARBOR_DIR so this never touches the real ~/.harbor state.
#
# notify.sh runs as its own process (not sourced), so stubbing osascript
# has to happen via PATH with a real executable, not an exported bash
# function — an exported function's side effects live in the child
# process's own variable scope and never propagate back to this script.
set -uo pipefail
cd "$(dirname "$0")/.."

SCRATCH=$(mktemp -d)
export HARBOR_DIR="$SCRATCH"
fail=0

mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/osascript" <<'STUB'
#!/usr/bin/env bash
echo "NOTIFY: $*" >> "$HARBOR_DIR/notify.log"
STUB
chmod +x "$SCRATCH/bin/osascript"
export PATH="$SCRATCH/bin:$PATH"

count() { [ -f "$SCRATCH/notify.log" ] && wc -l < "$SCRATCH/notify.log" | tr -d ' ' || echo 0; }

# Case 1: first-ever run (no prev.json) with an ok status must NOT notify.
cp test/fixtures/status-ok.json "$SCRATCH/status.json"
rm -f "$SCRATCH/prev.json"
bin/notify.sh
if [ "$(count)" -eq 0 ]; then
  echo "ok: ok-with-no-prev does not notify"
else
  echo "FAIL: ok-with-no-prev should not notify, got $(count) notifications"
  fail=1
fi

# Case 2: transition ok -> failed MUST notify exactly once.
cp test/fixtures/status-ok.json "$SCRATCH/prev.json"
cp test/fixtures/status-failed.json "$SCRATCH/status.json"
rm -f "$SCRATCH/notify.log"
bin/notify.sh
if [ "$(count)" -eq 1 ]; then
  echo "ok: failed transition notifies exactly once"
else
  echo "FAIL: expected exactly 1 notification, got $(count)"
  fail=1
fi

# Case 3: already-failed -> failed again must NOT re-notify.
cp test/fixtures/status-failed.json "$SCRATCH/prev.json"
cp test/fixtures/status-failed.json "$SCRATCH/status.json"
rm -f "$SCRATCH/notify.log"
bin/notify.sh
if [ "$(count)" -eq 0 ]; then
  echo "ok: repeat-failed does not re-notify"
else
  echo "FAIL: expected 0 notifications on repeat failure, got $(count)"
  fail=1
fi

rm -rf "$SCRATCH"
exit $fail
