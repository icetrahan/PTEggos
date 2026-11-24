#!/bin/bash
# Behaviour test for the gore section start-evrima.sh writes into Game.ini from the panel's switches (A1173):
#   server_settings.enableBiteGore / enableDismemberment / spawnLooseChunks
#   -> [/Script/TheIsle.TIRuntimeGoreSettings] bEnableRuntimeBiteGore / bEnableDismemberment / bSpawnLooseChunks
# Runs the REAL lines lifted from the shipping wrapper, never a copy of them. Needs jq.
#   bash isles/evrima-linux/test_gore.sh [wrapper]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WRAPPER="${1:-$HERE/start-evrima.sh}"
PASS=0; FAIL=0
ok()  { if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL $1"; fi; }

lift() { awk -v a="$1" -v b="$2" 'index($0,a)==1{on=1} on && index($0,b)==1{exit} on{print}' "$WRAPPER"; }
BLOCK=$(lift '# Gore (A1173)' "MASS_HDR=")
[ -n "$BLOCK" ] || { echo "FAIL anchor not found: gore block"; exit 1; }
# The wrapper's own reader, lifted too, so the test reads the plane document the way the wrapper does.
CJ=$(grep -m1 '^cj()' "$WRAPPER")
[ -n "$CJ" ] || { echo "FAIL anchor not found: cj()"; exit 1; }
eval "$CJ"
JQ="${JQ:-jq}"
command -v "$JQ" >/dev/null || { echo "REFUSED: jq not found; this test cannot run without it"; exit 2; }

log()  { echo "[primal] $*"; }
warn() { echo "[primal] WARN: $*"; }
GTMPL=$(cat "$HERE/Game.ini.tmpl")
HDR='[/Script/TheIsle.TIRuntimeGoreSettings]'
count() { grep -ciE "$2" <<<"$1"; }
section() { awk -v h="$HDR" '/^\[/{on=($0==h); next} on' <<<"$1"; }

run() { # $1 server_settings JSON (or empty), [$2 template]
    if [ -n "$1" ]; then CANON="{\"config\":{\"server_settings\":$1}}"; else CANON=""; fi
    GI="${2:-$GTMPL}"
    OUT=$(eval "$BLOCK" 2>&1; printf '\x1e%s' "$GI")
    GI_OUT="${OUT#*$'\x1e'}"; LOG_OUT="${OUT%%$'\x1e'*}"
}
K=(bEnableRuntimeBiteGore bEnableDismemberment bSpawnLooseChunks)
F=(enableBiteGore enableDismemberment spawnLooseChunks)

echo "1 - all off (the game's default): no gore section, the template untouched"
for c in '' '{"serverName":"x"}' '{"enableBiteGore":false,"enableDismemberment":false,"spawnLooseChunks":false}' \
         '{"enableBiteGore":"true","enableDismemberment":"True","spawnLooseChunks":"1"}' \
         '{"enableBiteGore":1,"enableDismemberment":1,"spawnLooseChunks":1}'; do
    run "$c"
    ok "${c:-no config}: no gore section" '[ "$(count "$GI_OUT" "^\[/Script/TheIsle\.TIRuntimeGoreSettings\]")" = 0 ]'
    ok "${c:-no config}: template unchanged" '[ "$GI_OUT" = "$GTMPL" ]'
    ok "${c:-no config}: the boot says gore off" 'grep -q "Game.ini: gore off" <<<"$LOG_OUT"'
done

echo "2 - each switch alone, then all three"
for on in 0 1 2 012; do
    js="{"; for j in 0 1 2; do [[ "$on" == *$j* ]] && v=true || v=false; js+="\"${F[$j]}\":$v,"; done; js="${js%,}}"
    run "$js"
    BODY=$(section "$GI_OUT")
    ok "$on: exactly one gore section" '[ "$(count "$GI_OUT" "^\[/Script/TheIsle\.TIRuntimeGoreSettings\]")" = 1 ]'
    for j in 0 1 2; do
        [[ "$on" == *$j* ]] && w=True || w=False
        ok "$on: ${K[$j]}=$w" '[ "$(grep -cx "${K[$j]}=$w" <<<"$BODY")" = 1 ]'
        ok "$on: ${K[$j]} once" '[ "$(count "$GI_OUT" "^[[:space:]]*${K[$j]}[[:space:]]*=")" = 1 ]'
    done
    ok "$on: the template is kept whole before it" '[ "${GI_OUT:0:${#GTMPL}}" = "$GTMPL" ]'
    ok "$on: the boot names what is on" 'grep -q "Game.ini: gore on: .*${K[${on:0:1}]}" <<<"$LOG_OUT"'
done

echo "3 - a stale gore section is replaced, never doubled; turned off it is removed"
STALE="$GTMPL"$'\n\n'"$HDR"$'\nbEnableRuntimeBiteGore=True\nbEnableDismemberment=True\nbSpawnLooseChunks=True'
run '{"enableBiteGore":false,"enableDismemberment":true,"spawnLooseChunks":false}' "$STALE"
ok "stale + dismemberment only: one section" '[ "$(count "$GI_OUT" "^\[/Script/TheIsle\.TIRuntimeGoreSettings\]")" = 1 ]'
ok "stale + dismemberment only: bite gore now False" '[ "$(section "$GI_OUT" | grep -cx "bEnableRuntimeBiteGore=False")" = 1 ]'
run '{"enableBiteGore":false,"enableDismemberment":false,"spawnLooseChunks":false}' "$STALE"
ok "stale + all off: section removed" '[ "$(count "$GI_OUT" "^\[/Script/TheIsle\.TIRuntimeGoreSettings\]")" = 0 ]'
ok "stale + all off: no orphan gore key" '[ "$(count "$GI_OUT" "^[[:space:]]*b(EnableRuntimeBiteGore|EnableDismemberment|SpawnLooseChunks)[[:space:]]*=")" = 0 ]'
LOWER="$GTMPL"$'\n\n[/script/theisle.tiruntimegoresettings]\nbEnableRuntimeBiteGore=True'
run '{"enableBiteGore":false}' "$LOWER"
ok "a lower-case stale header is removed too" '[ "$(count "$GI_OUT" "^\[/script/theisle\.tiruntimegoresettings\]")" = 0 ]'

echo
echo "gore: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
