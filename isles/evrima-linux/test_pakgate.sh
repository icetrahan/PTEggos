#!/usr/bin/env bash
# Behaviour test for the pak gate in start-evrima.sh: the pak mounts only on a game build its manifest
# lists in `gameBuilds`; anything else moves the triplet to _primal/pak-held and tells the plane.
# Runs the REAL lines lifted from the shipping wrapper against fake manifests, installs and plane.
#   bash isles/evrima-linux/test_pakgate.sh [wrapper]     (default: ./start-evrima.sh beside it)
HERE=$(cd "$(dirname "$0")" && pwd)
WRAPPER=${1:-$HERE/start-evrima.sh}
BLOCK=$(sed -n '/^PAK_HELD_DIR=/,/^if \[ "\${PAK_GATE%% \*}" = "open" \]; then/p' "$WRAPPER" | sed '$d')
[ -n "$BLOCK" ] || { echo "FAIL anchor not found in $WRAPPER (no pak gate)"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok() { if [ "$2" = 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "  FAIL $1 ${3:-}"; fi; }
log()  { echo "[primal] $*"; }
warn() { echo "[primal] WARN: $*"; }
env_or() { [ -n "$1" ] && echo "$1" || echo "$2"; }
m_field() { grep -o "\"$2\" *: *\"[^\"]*\"" <<<"$1" | head -1 | sed 's/.*: *"//; s/"$//'; }
manifest_buildid() { grep -o '"buildid"[[:space:]]*"[0-9]*"' "$1" 2>/dev/null | head -n1 | grep -o '[0-9][0-9]*'; }
# The manifest GET answers $FAKE_MANIFEST (empty = unreachable); a boot-report POST is recorded.
curl() {
    case " $* " in
        *" -X POST "*) printf '%s\n' "$*" | grep -o '{"stage".*}' >> "$REPORTS"; printf '{"ok":true,"recorded":true}\n200'; return 0 ;;
    esac
    [ -n "$FAKE_MANIFEST" ] || return 22
    printf '%s' "$FAKE_MANIFEST"
}
man() { # $1 = version, $2 = gameBuilds JSON or "" for none
    local gb=""; [ -n "$2" ] && gb=",\"gameBuilds\":$2"
    printf '{"version":"%s","build":"BUILD %s"%s,"files":[{"name":"pakchunk50-Windows_P.ucas","url":"u","sha256":"x","size":1}]}' "$1" "$1" "$gb"
}

# $1 = installed build ("" = no appmanifest), $2 = manifest JSON ("" = unreachable), $3 = ENABLE_PRIMAL_MOD.
# Leaves: $CASE (server folder), $OUT (the block's log).
run_case() {
    CASE="$WORK/$RANDOM$RANDOM"; ROOT="$CASE/server"; PRIM="$ROOT/_primal"; PAKS_DIR="$ROOT/TheIsle/Content/Paks"
    PAK_VER_FILE="$PRIM/primal-pak.version"; R2_BASE="https://r2.example"; DATA_BASE="https://plane.example"; PHSK="phsk_test"
    REPORTS="$CASE/reports.jsonl"
    mkdir -p "$PRIM" "$PAKS_DIR" "$ROOT/steamapps"
    for e in pak ucas utoc; do echo old > "$PAKS_DIR/pakchunk50-Windows_P.$e"; done
    echo 193 > "$PAK_VER_FILE"
    [ -n "$1" ] && echo "\"AppState\" { \"buildid\"  \"$1\" }" > "$ROOT/steamapps/appmanifest_412680.acf"
    [ -n "${KEPT:-}" ] && printf '%s' "$KEPT" > "$PRIM/primal-pak.gamebuilds"
    [ -n "${MARK:-}" ] && echo pak_game_build_unproven > "$PRIM/primal-pakgate.pending"
    FAKE_MANIFEST="$2"; ENABLE_PRIMAL_MOD="$3"
    OUT=$(eval "$BLOCK"; wait; echo "GATE=$PAK_GATE")
}
mounted() { [ -f "$PAKS_DIR/pakchunk50-Windows_P.ucas" ] && [ -f "$PAKS_DIR/pakchunk50-Windows_P.utoc" ]; }
held()    { [ -f "$PRIM/pak-held/pakchunk50-Windows_P.ucas" ] && ! ls "$PAKS_DIR"/pakchunk50-Windows_P.* >/dev/null 2>&1 && [ ! -f "$PAK_VER_FILE" ]; }

run_case 26883482 "$(man 194 '["24664709","26883482"]')" 1
mounted; ok "proven build keeps the pak" $?
echo "$OUT" | grep -q 'GATE=open proven'; ok "proven build reads open/proven" $? "$OUT"
[ ! -s "$REPORTS" ]; ok "a proven boot with no pending mark reports nothing" $?

run_case 26883482 "$(man 193 '["24664709"]')" 1
held; ok "unproven build holds the pak" $?
echo "$OUT" | grep -q 'pak-gate: game build 26883482, pak 193 from the manifest -> VANILLA (pak_game_build_unproven)'; ok "unproven boot says so in the log" $? "$OUT"
grep -q '"ok":false' "$REPORTS" && grep -q '"skipped":"pak_game_build_unproven"' "$REPORTS" && grep -q '"gameBuild":"26883482"' "$REPORTS"; ok "unproven boot is reported to the plane, distinguishably" $? "$(cat "$REPORTS" 2>/dev/null)"
[ -f "$PRIM/primal-pakgate.pending" ]; ok "unproven boot leaves the mark the reopening boot clears" $?

run_case 26883482 "$(man 193 '')" 1
held; ok "a manifest with no gameBuilds holds the pak (fail closed)" $?
echo "$OUT" | grep -q 'GATE=closed pak_proof_missing'; ok "no list reads pak_proof_missing" $? "$OUT"

run_case 26883482 "$(man 193 '[]')" 1
held; ok "an empty gameBuilds holds the pak" $?

run_case 26883482 "$(man lab '["*"]')" 1
mounted; ok "a lab manifest [\"*\"] mounts on any build" $?
echo "$OUT" | grep -q 'GATE=open any_build'; ok "lab manifest reads any_build" $? "$OUT"

run_case "" "$(man 194 '["26883482"]')" 1
held; ok "an unreadable installed build holds the pak" $?
echo "$OUT" | grep -q 'GATE=closed game_build_unknown'; ok "no appmanifest reads game_build_unknown" $? "$OUT"

KEPT=$'193\nlisted\n26883482' run_case 26883482 "" 1
mounted; ok "manifest unreachable: the list kept with the same pak decides (open)" $?
echo "$OUT" | grep -q 'from the list kept with pak 193'; ok "the kept list is named in the log" $? "$OUT"

KEPT=$'190\nlisted\n26883482' run_case 26883482 "" 1
held; ok "manifest unreachable: a kept list for ANOTHER pak version does not open the gate" $?

run_case 26883482 "" 1
held; ok "manifest unreachable and nothing kept: held" $?

run_case 26883482 "$(man 194 '["26883482"]')" 0
held; ok "ENABLE_PRIMAL_MOD=0 takes a pak left on disk off too" $?
grep -q '"skipped":"mod_off"' "$REPORTS"; ok "mod off is reported as mod_off, so the plane does not restart it to bring the pak back" $? "$(cat "$REPORTS" 2>/dev/null)"
! echo "$OUT" | grep -q 'BOOTING WITHOUT'; ok "mod off prints no gate banner" $? "$OUT"

MARK=1 run_case 26883482 "$(man 194 '["26883482"]')" 1
mounted; ok "a proven pak mounts again after a held boot" $?
grep -q '"ok":true' "$REPORTS"; ok "the reopening boot tells the plane" $? "$(cat "$REPORTS" 2>/dev/null)"
[ ! -f "$PRIM/primal-pakgate.pending" ]; ok "the mark is cleared once the plane recorded it" $?

run_case 26883482 "$(man 193 '["2688348"]')" 1
held; ok "a listed prefix of the build is not the build" $?

echo "pak gate (linux): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
