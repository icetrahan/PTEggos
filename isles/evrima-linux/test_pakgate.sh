#!/usr/bin/env bash
# Behaviour test for the pak gate in start-evrima.sh: the pak mounts only on a game build its manifest
# lists in `gameBuilds`; anything else moves the triplet to _primal/pak-held and tells the plane.
# Runs the REAL lines lifted from the shipping wrapper against fake manifests, installs and plane.
#   bash isles/evrima-linux/test_pakgate.sh [wrapper]     (default: ./start-evrima.sh beside it)
HERE=$(cd "$(dirname "$0")" && pwd)
WRAPPER=${1:-$HERE/start-evrima.sh}
BLOCK=$(sed -n '/^PAK_HELD_DIR=/,/^if \[ "\${PAK_GATE%% \*}" = "open" \]; then/p' "$WRAPPER" | sed '$d')
[ -n "$BLOCK" ] || { echo "FAIL anchor not found in $WRAPPER (no pak gate)"; exit 1; }
# The download step that follows the gate, up to its closing fi.
DL=$(awk '/^if \[ "\$\{PAK_GATE%% \*\}" = "open" \]; then$/{f=1} /^# CONFIRM-STARTUP IS GONE/{f=0} f' "$WRAPPER")
while [ -n "$DL" ] && [ "$(printf '%s\n' "$DL" | tail -n1)" != "fi" ]; do DL=$(printf '%s\n' "$DL" | sed '$d'); done
[ -n "$DL" ] || { echo "FAIL anchor not found in $WRAPPER (no pak download step)"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok() { if [ "$2" = 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "  FAIL $1 ${3:-}"; fi; }
log()  { echo "[primal] $*"; }
warn() { echo "[primal] WARN: $*"; }
env_or() { [ -n "$1" ] && echo "$1" || echo "$2"; }
m_field() { grep -o "\"$2\" *: *\"[^\"]*\"" <<<"$1" | head -1 | sed 's/.*: *"//; s/"$//'; }
manifest_buildid() { grep -o '"buildid"[[:space:]]*"[0-9]*"' "$1" 2>/dev/null | head -n1 | grep -o '[0-9][0-9]*'; }
m_fields() { grep -o "\"$2\" *: *\"[^\"]*\"" <<<"$1" | sed 's/.*: *"//; s/"$//'; }
sha256_of() { [ -f "$1" ] && sha256sum "$1" | awk '{print $1}' || echo ""; }
# The manifest GET answers $FAKE_MANIFEST (empty = unreachable); a download (-o) writes $FAKE_BODY;
# a boot-report POST is recorded.
curl() {
    case " $* " in
        *" -X POST "*) printf '%s\n' "$*" | grep -o '{"stage".*}' >> "$REPORTS"; printf '{"ok":true,"recorded":true}\n200'; return 0 ;;
        *" -o "*) local a prev="" out=""; for a in "$@"; do [ "$prev" = "-o" ] && out=$a; prev=$a; done
                  printf '%s' "$FAKE_BODY" > "$out"; return 0 ;;
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
    [ -n "${HELD:-}" ] && mkdir -p "$PRIM/pak-held" && echo "$HELD" > "$PRIM/pak-held/pakchunk50-Windows_P.ucas"
    FAKE_MANIFEST="$2"; ENABLE_PRIMAL_MOD="$3"
    OUT=$(eval "$BLOCK"; [ -n "${WITH_DL:-}" ] && eval "$DL"; wait; echo "GATE=$PAK_GATE")
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

# The download step: a failed update falls back to the pak on disk only when that pak's own kept list proves it.
man_sha() { printf '{"version":"%s","build":"BUILD %s","gameBuilds":%s,"files":[{"name":"pakchunk50-Windows_P.ucas","url":"u","sha256":"%s","size":1}]}' "$1" "$1" "$2" "$3"; }
NEW_SHA=$(printf 'NEW' | sha256sum | awk '{print $1}'); OLD_SHA=$(printf 'old\n' | sha256sum | awk '{print $1}')

WITH_DL=1 FAKE_BODY=junk KEPT=$'193\nlisted\n26883482' run_case 26883482 "$(man_sha 194 '["26883482"]' "$NEW_SHA")" 1
mounted && [ "$(cat "$PAK_VER_FILE")" = 193 ]; ok "failed update, pak 193 proven by its kept list: 193 stays in use" $? "$OUT"
echo "$OUT" | grep -q 'pak 193 stays in use: its kept list says proven on game build 26883482'; ok "the log says the kept list keeps it" $? "$OUT"
[ "$(head -n1 "$PRIM/primal-pak.gamebuilds")" = 193 ]; ok "the kept list still describes 193, never the failed 194" $?
[ ! -s "$REPORTS" ]; ok "a pak that stays in use reports nothing" $? "$(cat "$REPORTS" 2>/dev/null)"

WITH_DL=1 FAKE_BODY=junk run_case 26883482 "$(man_sha 194 '["26883482"]' "$NEW_SHA")" 1
held; ok "failed update, pak 193 with no kept list: held" $? "$OUT"
echo "$OUT" | grep -q 'pak 193 on disk is not proven on this game build (pak_proof_missing)'; ok "the log says why" $? "$OUT"
grep -q '"skipped":"pak_proof_missing"' "$REPORTS" && grep -q 'update to pak 194 failed' "$REPORTS"; ok "the held boot is reported to the plane" $? "$(cat "$REPORTS" 2>/dev/null)"
[ "$(cat "$PRIM/primal-pakgate.pending" 2>/dev/null)" = pak_proof_missing ]; ok "the held boot leaves the mark the reopening boot clears" $?

WITH_DL=1 FAKE_BODY=junk KEPT=$'193\nlisted\n24664709' run_case 26883482 "$(man_sha 194 '["26883482"]' "$NEW_SHA")" 1
held; ok "failed update, pak 193 kept-proven on another build only: held" $? "$OUT"
grep -q '"skipped":"pak_game_build_unproven"' "$REPORTS"; ok "reported as pak_game_build_unproven" $? "$(cat "$REPORTS" 2>/dev/null)"

WITH_DL=1 FAKE_BODY=NEW run_case 26883482 "$(man_sha 194 '["26883482"]' "$NEW_SHA")" 1
[ "$(cat "$PAKS_DIR/pakchunk50-Windows_P.ucas")" = NEW ] && [ "$(cat "$PAK_VER_FILE")" = 194 ]; ok "a verified update places pak 194" $? "$OUT"
[ "$(head -n1 "$PRIM/primal-pak.gamebuilds")" = 194 ] && [ "$(tail -n1 "$PRIM/primal-pak.gamebuilds")" = 26883482 ]; ok "the kept list moves to 194 once 194 is placed" $?

WITH_DL=1 run_case 26883482 "$(man_sha 193 '["24664709","26883482"]' "$OLD_SHA")" 1
echo "$OUT" | grep -q 'up to date (193)' && [ "$(head -n1 "$PRIM/primal-pak.gamebuilds")" = 193 ]; ok "an up-to-date pak gets its kept list refreshed" $? "$OUT"

# Once the gate opens, a held triplet that is not the manifest's pak goes; the manifest's own pak, or no manifest, keeps it.
HELD="pak 193 bytes" run_case 26883482 "$(man_sha 194 '["26883482"]' "$NEW_SHA")" 1
[ ! -d "$PRIM/pak-held" ]; ok "an open gate clears a held triplet of another pak" $? "$OUT"
echo "$OUT" | grep -q 'cleared _primal/pak-held: it held another pak than 194'; ok "the clearing is in the log, naming the manifest pak" $? "$OUT"
mounted; ok "clearing pak-held leaves the mounted pak alone" $?

HELD_SHA=$(printf 'pak 194 bytes\n' | sha256sum | awk '{print $1}')
HELD="pak 194 bytes" run_case 26883482 "$(man_sha 194 '["26883482"]' "$HELD_SHA")" 1
[ -f "$PRIM/pak-held/pakchunk50-Windows_P.ucas" ]; ok "an open gate keeps a held triplet that is the manifest's own pak" $? "$OUT"
! echo "$OUT" | grep -q 'cleared _primal'; ok "a kept pak-held is not reported as cleared" $? "$OUT"

HELD="pak 190 bytes" KEPT=$'193\nlisted\n26883482' run_case 26883482 "" 1
[ -f "$PRIM/pak-held/pakchunk50-Windows_P.ucas" ]; ok "manifest unreachable: pak-held is left as it is (nothing to compare with)" $? "$OUT"

HELD="pak 190 bytes" run_case 26883482 "$(man 193 '["24664709"]')" 1
held; ok "a held boot over an older pak-held still holds (the triplet is moved over it)" $?

echo "pak gate (linux): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
