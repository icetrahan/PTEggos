#!/bin/bash
# Behaviour test for the two game-native lines start-evrima.sh renders from the panel's settings:
#   A  Game.ini   GlobalAISpawnLimit        <- mod_settings.aiMaxCount ("Most AI alive at once")
#   B  Engine.ini ti.TreeDestruction.Enabled <- mod_settings.treeKnockdownOn ("Tree knockdown")
# Runs the REAL lines lifted from the shipping wrapper, never a copy of them.
#   bash isles/evrima-linux/test_treeaicap.sh [wrapper]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WRAPPER="${1:-$HERE/start-evrima.sh}"
PASS=0; FAIL=0
ok()  { if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL $1"; fi; }

# Lines from the first that starts with $1 up to (not including) the first after it that starts with $2.
lift() { awk -v a="$1" -v b="$2" 'index($0,a)==1{on=1} on && index($0,b)==1{exit} on{print}' "$WRAPPER"; }
BLOCK_A=$(lift '# GlobalAISpawnLimit, the game' "MASS_HDR=")
BLOCK_B=$(awk 'index($0,"    # Tree knockdown: the switch the pak reads")==1{on=1} on{buf[++n]=$0} on && index($0,"    log \"Engine.ini: no Primal session block")==1{for(i=1;i<=n-2;i++)print buf[i]; exit}' "$WRAPPER")
[ -n "$BLOCK_A" ] || { echo "FAIL anchor not found: GlobalAISpawnLimit block"; exit 1; }
[ -n "$BLOCK_B" ] || { echo "FAIL anchor not found: tree knockdown block"; exit 1; }

log()  { echo "[primal] $*"; }
warn() { echo "[primal] WARN: $*"; }
# Stand-ins for the wrapper's canonical-config readers: MS_* holds this case's mod_settings.
c_has() { [ "$1" = "mod_settings" ] && [ "$2" = "aiMaxCount" ] && [ "${MS_HAS:-0}" = "1" ]; }
c_str() { printf '%s' "${MS_AIMAX:-}"; }

NL=$'\n'
GTMPL=$(cat "$HERE/Game.ini.tmpl")
ETMPL=$(cat "$HERE/Engine.ini.tmpl")
count() { grep -ciE "$2" <<<"$1"; }
session() { awk '/^\[\/script\/theisle\.tigamesession\]/{on=1; next} /^\[/{on=0} on' <<<"$1"; }
cvars()   { awk '/^\[ConsoleVariables\]/{on=1; next} /^\[/{on=0} on' <<<"$1"; }

run_a() { # $1 mod, $2 key, $3 has-field, $4 value, [$5 template]
    ENABLE_PRIMAL_MOD="$1"; PHSK="$2"; MS_HAS="$3"; MS_AIMAX="$4"; GI="${5:-$GTMPL}"
    OUT=$(eval "$BLOCK_A" 2>&1; printf '\x1e%s' "$GI")
    GI_OUT="${OUT#*$'\x1e'}"; LOG_OUT="${OUT%%$'\x1e'*}"
}

echo "A - GlobalAISpawnLimit from Most AI alive at once"
for c in "40:40" "150:150" "95.7:95" "0:1" "-3:1" "330:330"; do
    v="${c%%:*}"; w="${c##*:}"
    run_a 1 phsk_test 1 "$v"
    ok "$v: GlobalAISpawnLimit=$w in the session section" '[ "$(session "$GI_OUT" | grep -cx "GlobalAISpawnLimit=$w")" = 1 ]'
    ok "$v: exactly once" '[ "$(count "$GI_OUT" "^[[:space:]]*GlobalAISpawnLimit[[:space:]]*=")" = 1 ]'
    ok "$v: nothing else changed" '[ "$(grep -vx "GlobalAISpawnLimit=$w" <<<"$GI_OUT")" = "$GTMPL" ]'
    ok "$v: the boot says it" 'grep -qF "Game.ini: GlobalAISpawnLimit=$w (" <<<"$LOG_OUT"'
done
for c in "mod off|0|phsk_test|1|40|our mod is off" "no key|1||1|40|our mod is off" \
         "no field|1|phsk_test|0||no plane config" "not a number|1|phsk_test|1|abc|is not a number"; do
    IFS='|' read -r n mod key has val why <<<"$c"
    run_a "$mod" "$key" "$has" "$val"
    ok "$n: no line" '[ "$(count "$GI_OUT" "GlobalAISpawnLimit")" = 0 ]'
    ok "$n: Game.ini untouched" '[ "$GI_OUT" = "$GTMPL" ]'
    ok "$n: said why" 'grep -qF "GlobalAISpawnLimit not set - " <<<"$LOG_OUT" && grep -qF "$why" <<<"$LOG_OUT"'
done
run_a 1 phsk_test 1 40 "${GTMPL/AIDensity=\{\{AIDensity\}\}/AIDensity={{AIDensity}}${NL}globalaispawnlimit = 999}"
ok "a hand-set line is replaced, never doubled" '[ "$(count "$GI_OUT" "^[[:space:]]*GlobalAISpawnLimit[[:space:]]*=")" = 1 ] && ! grep -q 999 <<<"$GI_OUT"'
run_a 1 phsk_test 1 40 "${GTMPL/\[\/script\/theisle.tigamesession\]/[/script/theisle.other]}"
ok "no session section: said, not silent" 'grep -qF "no [/script/theisle.tigamesession] section - GlobalAISpawnLimit NOT set" <<<"$LOG_OUT"'
ok "...and nothing was added" '[ "$(count "$GI_OUT" "GlobalAISpawnLimit")" = 0 ]'

run_b() { # $1 TreeKnockdownOn, [$2 template]
    declare -gA PAK_EXTRA=([TreeKnockdownOn]="$1"); ENG="${2:-$ETMPL}"
    OUT=$(eval "$BLOCK_B" 2>&1; printf '\x1e%s' "$ENG")
    ENG_OUT="${OUT#*$'\x1e'}"; LOG_OUT="${OUT%%$'\x1e'*}"
}
echo "B - ti.TreeDestruction.Enabled from Tree knockdown"
run_b False
ok "off: the line is in [ConsoleVariables]" '[ "$(cvars "$ENG_OUT" | grep -cx "ti.TreeDestruction.Enabled=0")" = 1 ]'
ok "off: exactly once in the file" '[ "$(count "$ENG_OUT" "^[[:space:]]*ti\.TreeDestruction\.Enabled[[:space:]]*=")" = 1 ]'
ok "off: the streaming cvars kept" 'cvars "$ENG_OUT" | grep -qx "wp.Runtime.EnableServerStreamingOut=1"'
ok "off: nothing else changed" '[ "$(grep -vx "ti.TreeDestruction.Enabled=0" <<<"$ENG_OUT")" = "$ETMPL" ]'
ok "off: the boot says it" 'grep -qF "ti.TreeDestruction.Enabled=0 (Tree knockdown off" <<<"$LOG_OUT"'
run_b True
ok "on: no line" '[ "$(count "$ENG_OUT" "TreeDestruction")" = 0 ]'
ok "on: Engine.ini untouched" '[ "$ENG_OUT" = "$ETMPL" ]'
ok "on: the boot says it" 'grep -qF "tree knockdown on (the game" <<<"$LOG_OUT"'
HAND="${ETMPL/wp.Runtime.EnableServerStreamingOut=1/wp.Runtime.EnableServerStreamingOut=1${NL}ti.treedestruction.enabled = 1}"
run_b False "$HAND"
ok "off over a hand-set =1: one line, =0" '[ "$(count "$ENG_OUT" "^[[:space:]]*ti\.TreeDestruction\.Enabled[[:space:]]*=")" = 1 ] && grep -qx "ti.TreeDestruction.Enabled=0" <<<"$ENG_OUT"'
run_b True "$HAND"
ok "on over a hand-set line: removed (the switch owns it)" '[ "$(count "$ENG_OUT" "TreeDestruction")" = 0 ]'
run_b False "${ETMPL/\[ConsoleVariables\]/[SomethingElse]}"
ok "no [ConsoleVariables]: said, not silent" 'grep -qF "no [ConsoleVariables] section - tree knockdown NOT turned off" <<<"$LOG_OUT"'
ok "...and nothing was added" '[ "$(count "$ENG_OUT" "TreeDestruction")" = 0 ]'

echo "C - placement"
nA=$(grep -nF '# GlobalAISpawnLimit, the game' "$WRAPPER" | head -1 | cut -d: -f1)
nW=$(grep -nF '> "$CONFIG_DIR/Game.ini"' "$WRAPPER" | head -1 | cut -d: -f1)
nM=$(grep -nF 'if [ "${ENABLE_PRIMAL_MOD:-0}" = "1" ] && [ -n "$PHSK" ]; then' "$WRAPPER" | awk -F: -v a="$nA" '$1>a{print $1; exit}')
nB=$(grep -nF '# Tree knockdown: the switch the pak reads' "$WRAPPER" | head -1 | cut -d: -f1)
nE=$(grep -nF '> "$CONFIG_DIR/Engine.ini"' "$WRAPPER" | head -1 | cut -d: -f1)
ok "the cap is set before Game.ini is written" '[ "${nA:-0}" -gt 0 ] && [ "${nW:-0}" -gt "$nA" ]'
ok "the tree line is inside the mod-on session branch, before Engine.ini is written" '[ "${nM:-0}" -gt 0 ] && [ "${nB:-0}" -gt "$nM" ] && [ "${nE:-0}" -gt "$nB" ]'
FB=$(grep -oE '^PAK_EXTRA\[TreeKnockdownOn\]="[A-Za-z]+"' "$WRAPPER" | head -1 | cut -d'"' -f2)
ok "with no plane config the wrapper falls back to tree knockdown on (the game's default)" '[ "$FB" = True ]'

if [ "$FAIL" -gt 0 ]; then echo "FAIL $PASS passed, $FAIL failed"; exit 1; fi
echo "PASS $PASS passed, $FAIL failed"
