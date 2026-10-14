#!/usr/bin/env bash
# Behaviour test for the clean-pull update block in start-evrima.sh (BACKLOG A702).
# Runs the REAL lines lifted from the shipping wrapper against a fake steamcmd that reproduces the
# stale-appmanifest bug: with steamapps present it trusts its manifest and does not move the build.
#   bash isles/evrima-linux/test_cleanupdate.sh [wrapper]     (default: ./start-evrima.sh beside it)
HERE=$(cd "$(dirname "$0")" && pwd)
WRAPPER=${1:-$HERE/start-evrima.sh}
BLOCK=$(sed -n '/^# A new Isle build is applied by a CLEAN pull/,/^# The gate is the binary this wrapper launches/p' "$WRAPPER" | sed '$d')
[ -n "$BLOCK" ] || { echo "anchor not found in $WRAPPER"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok() { if [ "$2" = 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "  FAIL $1 ${3:-}"; fi; }
log()  { echo "[primal] $*"; }
warn() { echo "[primal] WARN: $*"; }
curl() { return 0; }   # Steam reachable, without the network

FAKE="$WORK/steamcmd.sh"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" +app_info_print "*)
    echo info >> "$FAKE_DIR/calls.log"
    [ -n "$FAKE_LATEST" ] || exit 0
    printf 'AppID : 412680, change number : 1/1\n"412680"\n{\n\t"depots"\n\t{\n\t\t"branches"\n\t\t{\n\t\t\t"public"\n\t\t\t{\n\t\t\t\t"buildid"\t\t"555"\n\t\t\t}\n\t\t\t"evrima"\n\t\t\t{\n\t\t\t\t"buildid"\t\t"%s"\n\t\t\t\t"timeupdated"\t\t"1"\n\t\t\t}\n\t\t}\n\t}\n}\n' "$FAKE_LATEST"
    exit 0 ;;
esac
echo update >> "$FAKE_DIR/calls.log"
[ "$FAKE_PULL_FAILS" = 1 ] && exit 0
while [ $# -gt 0 ]; do [ "$1" = "+force_install_dir" ] && G=$2; shift; done
MAN="$G/steamapps/appmanifest_412680.acf"; BIN="$G/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping"
mkdir -p "$G/steamapps" "$(dirname "$BIN")"
if [ ! -f "$MAN" ]; then
    echo "build $FAKE_LATEST" > "$BIN"; echo "\"AppState\" { \"buildid\"  \"$FAKE_LATEST\" }" > "$MAN"
elif [ ! -f "$BIN" ]; then
    echo "build $(grep -o '[0-9][0-9]*' "$MAN" | head -n1)" > "$BIN"
fi
EOF
chmod +x "$FAKE"

# run_case installed mark latest [force|fails|leftover|noupdate]
run_case() {
    R="$WORK/c$RANDOM$RANDOM"; mkdir -p "$R/steamcmd" "$R/_primal" "$R/steamapps" "$R/TheIsle/Binaries/Linux"
    cp "$FAKE" "$R/steamcmd/steamcmd.sh"
    if [ -n "$1" ]; then
        echo "build $1" > "$R/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping"
        echo "\"AppState\" { \"buildid\"  \"$1\" }" > "$R/steamapps/appmanifest_412680.acf"
    fi
    echo placed > "$R/TheIsle/Binaries/Linux/primal-placed.so"
    [ -n "$2" ] && echo "$2" > "$R/_primal/primal-clean-build.txt"
    [ "$4" = leftover ] && mkdir -p "$R/TheIsle/Binaries.preupdate/Linux"
    OUT=$(
        cd "$R" || exit 1
        ROOT=$R; PRIM=$R/_primal; GAME_BINARY=$R/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping
        export FAKE_DIR=$R FAKE_LATEST=$3 FAKE_PULL_FAILS=$([ "$4" = fails ] && echo 1)
        FORCE_CLEAN_UPDATE=$([ "$4" = force ] && echo 1 || echo 0)
        AUTO_UPDATE=$([ "$4" = noupdate ] && echo 0 || echo 1)
        eval "$BLOCK" 2>&1
    )
    EXE=$(cat "$R/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping" 2>/dev/null)
    MARK=$(cat "$R/_primal/primal-clean-build.txt" 2>/dev/null)
    KEPT=1; [ -f "$R/TheIsle/Binaries/Linux/primal-placed.so" ] && KEPT=0
    PREV=1; [ -d "$R/TheIsle/Binaries.preupdate" ] && PREV=0
    UPDATES=$(grep -c '^update$' "$R/calls.log" 2>/dev/null)
}
t() { if eval "$2"; then ok "$1" 0; else ok "$1" 1 "$3"; fi; }

echo "parse - the evrima branch, never public's"
eval "$(sed -n '/^branch_buildid()/,/^}/p' "$WRAPPER")"
t 'evrima id' '[ "$(FAKE_LATEST=101 FAKE_DIR=$WORK "$FAKE" +app_info_print 412680 | branch_buildid evrima)" = 101 ]'
t 'missing branch is empty' '[ -z "$(FAKE_LATEST=101 FAKE_DIR=$WORK "$FAKE" +app_info_print 412680 | branch_buildid legacy)" ]'

echo "A - a new Isle build is pulled clean, and placed files survive it"
run_case 100 100 101
t 'new build running' '[ "$EXE" = "build 101" ]' "$EXE"
t 'placed file kept' '[ $KEPT = 0 ]'
t 'record moved to 101' '[ "$MARK" = 101 ]' "$MARK"
t 'nothing left aside' '[ $PREV = 1 ]'
t 'said so' 'echo "$OUT" | grep -q -- "-> new-build" && echo "$OUT" | grep -q "kept across the clean pull: primal-placed.so"'

echo "B - the stale-manifest bug: an in-place update would NOT have moved the build"
run_case 100 "" 101
t 'first boot with a stale install pulls clean' '[ "$EXE" = "build 101" ] && [ "$MARK" = 101 ]' "$EXE / $MARK"

echo "C - same build: plain validate, nothing set aside"
run_case 101 101 101
t 'untouched' '[ "$EXE" = "build 101" ] && [ $PREV = 1 ] && [ "$UPDATES" = 1 ] && echo "$OUT" | grep -q -- "-> current"'

echo "D - first boot with this code on a current install: adopt, no re-download"
run_case 101 "" 101
t 'adopted' '[ "$MARK" = 101 ] && [ "$UPDATES" = 1 ] && echo "$OUT" | grep -q -- "-> adopt"'

echo "E - Steam's build unreadable: said, plain validate, record unchanged"
run_case 100 100 ""
t 'unknown said' 'echo "$OUT" | grep -q -- "-> unknown" && echo "$OUT" | grep -q "WARN: update: Steam"'
t 'record and build unchanged' '[ "$MARK" = 100 ] && [ "$EXE" = "build 100" ]'

echo "F - the pull fails: the PREVIOUS build boots, loudly, and the next restart retries"
run_case 100 100 101 fails
t 'previous binary back' '[ "$EXE" = "build 100" ]' "$EXE"
t 'placed file back' '[ $KEPT = 0 ]'
t 'FAILED said' 'echo "$OUT" | grep -q "FAILED: the clean pull left no server binary"'
t 'record NOT moved' '[ "$MARK" = 100 ]' "$MARK"
t 'self-heal retried once' '[ "$UPDATES" = 2 ]' "$UPDATES"

echo "G - FORCE_CLEAN_UPDATE=1 pulls clean with no new build"
run_case 101 101 101 force
t 'forced' 'echo "$OUT" | grep -q -- "-> force" && echo "$OUT" | grep -q "clean pull: TheIsle" && [ "$EXE" = "build 101" ] && [ $KEPT = 0 ]'

echo "H - a Binaries.preupdate left by a boot stopped mid-pull is cleared"
run_case 101 101 101 leftover
t 'cleared' '[ $PREV = 1 ]'

echo "I - AUTO_UPDATE=0 skips the whole phase"
run_case 100 100 101 noupdate
t 'skipped' 'echo "$OUT" | grep -q "skipped (AUTO_UPDATE=0" && [ "$EXE" = "build 100" ] && [ "${UPDATES:-0}" = 0 ]'

echo
echo "test_cleanupdate: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
