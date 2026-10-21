#!/usr/bin/env bash
# Behaviour test for evrima-survival's two calls to Heaven's update manager (A795): with no
# API_BASE_URL the image names no host and calls nothing, and says so by name when SERVER_ID would
# have sent them. Runs the REAL settings line and Steps 1 and 6 lifted from the entrypoint, with a
# stand-in curl that records every call.
#   bash .github/scripts/test_survival_update_manager.sh [repo root]
ROOT=$(cd "${1:-$(dirname "$0")/../..}" && pwd)
SURV=$ROOT/isles/evrima-survival/entrypoint.sh
EGG=$ROOT/isles/evrima-survival/egg-evrima-survival.json
PY=""; for c in python3 python; do "$c" -c "" 2>/dev/null && { PY=$c; break; }; done # the first that runs, not the first on PATH
[ -n "$PY" ] || { echo "python is needed to read the egg"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
t() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "  FAIL $1 ${3:-}"; fi; }

{
    echo 'log()  { echo "[primal] $*"; }'
    echo 'warn() { echo "[primal] WARN: $*" >&2; }'
    echo 'curl() { echo "${@: -1}" >> "$CALLS"; printf "{\"blocked\":false}\n200"; }' # one line per call: its URL
    echo 'sleep() { :; }'
    grep -E '^API_BASE_URL=' "$SURV"
    sed -n '/^# ── Step 1: Update gate/,/^# ── Step 2/p' "$SURV" | head -n -1
    sed -n '/^# ── Step 6: Confirm startup/,/^# ── Step 7/p' "$SURV" | head -n -1
} > "$WORK/steps.sh"

run() { # $1 = case name; the rest = env for the steps
    local name=$1; shift
    : > "$WORK/$name.calls"
    env -i PATH="$PATH" CALLS="$WORK/$name.calls" UPDATE_GATE=1 "$@" bash "$WORK/steps.sh" > "$WORK/$name.out" 2>&1
    echo $? > "$WORK/$name.rc"
}

echo "0 - the lifted steps are the ones the image ships"
t 'the settings line is lifted' 'grep -q "^API_BASE_URL=" "$WORK/steps.sh"'
t 'Step 1 calls the update gate' 'grep -qF "/api/updates/server-status/" "$WORK/steps.sh"'
t 'Step 6 calls confirm-startup' 'grep -qF "/api/updates/confirm-startup" "$WORK/steps.sh"'

echo "1 - the deleted host is named nowhere in the image or its egg"
t 'entrypoint names no primalheaven host' '! grep -q "api\.primalheaven\.com" "$SURV"'
t 'egg names no primalheaven host' '! grep -q "api\.primalheaven\.com" "$EGG"'
t 'egg API_BASE_URL defaults empty and may stay empty' \
  '"$PY" -c "import json,sys; v=[x for x in json.load(open(sys.argv[1],encoding=\"utf-8\"))[\"variables\"] if x[\"env_variable\"]==\"API_BASE_URL\"][0]; sys.exit(0 if v[\"default_value\"]==\"\" and \"required\" not in v[\"rules\"] else 1)" "$EGG"'

echo "2 - SERVER_ID set, API_BASE_URL unset: no call, and both skips are named"
run unset SERVER_ID=42
t 'the steps run to the end' '[ "$(cat "$WORK/unset.rc")" = 0 ]' "$(cat "$WORK/unset.out")"
t 'curl is never called' '[ ! -s "$WORK/unset.calls" ]' "$(cat "$WORK/unset.calls")"
t 'the update gate says it skipped' 'grep -qF "Update gate SKIPPED: SERVER_ID is set but API_BASE_URL is not." "$WORK/unset.out"'
t 'the confirmation says it skipped' 'grep -qF "Startup confirmation SKIPPED: SERVER_ID is set but API_BASE_URL is not." "$WORK/unset.out"'

echo "3 - SERVER_ID unset: no call, as before"
run nosid
t 'curl is never called' '[ ! -s "$WORK/nosid.calls" ]'
t 'the gate says it is disabled' 'grep -qF "Update gate disabled or SERVER_ID unset" "$WORK/nosid.out"'

echo "4 - both set: the calls go to the host given, unchanged"
run set SERVER_ID=42 API_BASE_URL=https://update-manager.invalid
t 'two calls' '[ "$(wc -l < "$WORK/set.calls")" = 2 ]' "$(cat "$WORK/set.calls")"
t 'the gate asks the given host' 'grep -qF "https://update-manager.invalid/api/updates/server-status/42" "$WORK/set.calls"'
t 'the confirmation posts to the given host' 'grep -qF "https://update-manager.invalid/api/updates/confirm-startup" "$WORK/set.calls"'
t 'no skip is claimed' '! grep -q "SKIPPED" "$WORK/set.out"'

echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
