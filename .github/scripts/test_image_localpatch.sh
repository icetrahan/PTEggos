#!/usr/bin/env bash
# Behaviour test for the binary step of the two images that boot an Evrima Linux server outside egg 42:
# isles/evrima-survival and testing/deathmatch. Each patches the stock binary in place first (the
# PRIMAL LOCAL PATCH block, the same bytes in both) and falls back to the binary lane; a download is
# installed only when the binary's path reads back as it (#3875). Runs the REAL lines lifted from both
# entrypoints with a stand-in patcher (patch_worker.py's arguments, exit codes and report shape), a
# stand-in R2, lane and Norden. The real patcher on real game builds is proven in Docker (see the PR).
#   bash .github/scripts/test_image_localpatch.sh [repo root]
ROOT=$(cd "${1:-$(dirname "$0")/../..}" && pwd)
SURV=$ROOT/isles/evrima-survival/entrypoint.sh
DM=$ROOT/testing/deathmatch/entrypoint.sh
EGG42=$ROOT/isles/evrima-linux/start-evrima.sh
command -v python3 >/dev/null || { echo "python3 is needed to run the stand-in patcher"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok() { if [ "$2" = 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "  FAIL $1 ${3:-}"; fi; }
t() { if eval "$2"; then ok "$1" 0; else ok "$1" 1 "$3"; fi; }

block_of() { sed -n '/^# >>> PRIMAL LOCAL PATCH >>>$/,/^# <<< PRIMAL LOCAL PATCH <<<$/p' "$1"; }
step_of() { # the image's binary step, as it ships
    case "$1" in
        surv) sed -n '/^# ── Step 3: Modded binary/,/^# ── Step 4/p' "$SURV" | head -n -1 ;;
        dm)   sed -n '/^# Mod Update Check/,/^# Get final modded hash/p' "$DM" | head -n -1 ;;
    esac
}

echo "0 - the block is the same bytes in both images, and it says what egg 42 says"
BS=$(block_of "$SURV"); BD=$(block_of "$DM")
t 'block present in evrima-survival' '[ -n "$BS" ]'
t 'block present in deathmatch' '[ -n "$BD" ]'
t 'the two blocks are identical' '[ "$BS" = "$BD" ]' "$(diff <(echo "$BS") <(echo "$BD") | head -5)"
t 'exactly one block per image' '[ "$(grep -c "^# >>> PRIMAL LOCAL PATCH >>>$" "$SURV")" = 1 ] && [ "$(grep -c "^# >>> PRIMAL LOCAL PATCH >>>$" "$DM")" = 1 ]'
for s in 'binary: PATCHED LOCALLY (tool v' 'binary: already patched (' 'binary: LOCAL PATCH NOT APPLIED - ' \
         "binary: the lane's build for this vanilla is the same bytes" 'the two paths disagree' \
         "python3 is not in this server's image" 'did not patch this build: exit ' 'failed its sha256 check' \
         'patching with the copy kept from an earlier boot (tool v'; do
    t "egg 42 and the block both say: $s" 'grep -qF -- "$s" "$EGG42" && grep -qF -- "$s" <<<"$BS"'
done
R2_BASE=$(sed -n 's/^R2_BASE="\(.*\)"$/\1/p' "$EGG42")
t "the block's default manifest is egg 42's (\$R2_BASE/primal-voice-linux-tool/latest.json)" \
  '[ -n "$R2_BASE" ] && grep -qF -- "\${PRIMAL_PATCHER_MANIFEST:-$R2_BASE/primal-voice-linux-tool/latest.json}" <<<"$BS"'
for d in isles/evrima-survival testing/deathmatch; do
    t "$d/Dockerfile installs python3" 'grep -Eq "^[[:space:]]+python3 \\\\[[:space:]]*$" "$ROOT/$d/Dockerfile"'
done
first_line() { grep -n -m1 -- "$2" "$1" | cut -d: -f1; }
t 'evrima-survival runs the local patch before the lane' \
  '[ "$(first_line "$SURV" "lp_run && MOD_READY=true")" -lt "$(first_line "$SURV" "CHECK=\$(curl")" ]'
t 'deathmatch runs the local patch before the lane' \
  '[ "$(first_line "$DM" "lp_run && MOD_DOWNLOADED=true")" -lt "$(first_line "$DM" "CHECK_RESPONSE=\$(curl")" ]'

# --- the stand-in patcher: patch_worker.py's contract on a small file. Byte 16 is the one site:
# 0x74 = stock, 0xEB = patched, anything else = the pattern does not resolve.
SRV="$WORK/srv"; mkdir -p "$SRV"
cat > "$SRV/patch_worker.py" <<'EOF'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
rep = sys.argv[sys.argv.index("--report") + 1]
mode = os.environ.get("FAKE_PATCHER", "")
if mode == "crash":
    raise SystemExit("Traceback (most recent call last): TypeError: unsupported operand")
data = bytearray(open(src, "rb").read())
site = data[16] if len(data) > 16 else None
item = {"name": "gate", "match_count": 1, "patch_offset": "0x10"}
if site == 0x74:
    data[16] = 0xEB; item["status"] = "patched"
elif site == 0xEB:
    item["status"] = "already_patched"
else:
    item.update(status="failed", match_count=0, reason="signature must match exactly once")
ok = item["status"] != "failed"
if mode == "lie":
    ok = False
if ok or mode == "lie":
    if mode != "noout":
        open(dst, "wb").write(bytes(data[:-1] if mode == "short" else data))
json.dump({"patches": [item], "success": ok if mode != "noout" else True}, open(rep, "w"), indent=2)
sys.exit(0 if ok or mode in ("lie", "noout") else 2)
EOF
echo '{"platform": "linux", "patches": []}' > "$SRV/patches_linux.json"
sha() { sha256sum "$1" | awk '{print $1}'; }
manifest() { # $1 = sha256 of patch_worker.py, $2 = sha256 of patches_linux.json
    printf '{\n "version": "T1",\n "files": [\n' > "$SRV/manifest.json"
    printf '  {"name": "primal-voice-linux.sh", "url": "https://r2.test/tool/T1/primal-voice-linux.sh", "sha256": "%s", "size": 1},\n' "$(printf '0%.0s' $(seq 64))" >> "$SRV/manifest.json"
    printf '  {"name": "patch_worker.py", "url": "https://r2.test/tool/T1/patch_worker.py", "sha256": "%s", "size": 1},\n' "$1" >> "$SRV/manifest.json"
    printf '  {"name": "patches_linux.json", "url": "https://r2.test/tool/T1/patches_linux.json", "sha256": "%s", "size": 1}\n ]\n}\n' "$2" >> "$SRV/manifest.json"
}
GOOD_PW=$(sha "$SRV/patch_worker.py"); GOOD_SPEC=$(sha "$SRV/patches_linux.json")
manifest "$GOOD_PW" "$GOOD_SPEC"

# The lane's and Norden's modded binaries: over the 150 MB floor, sparse so they cost no disk.
truncate -s 160M "$SRV/lane.bin"; LANE_MD5=$(md5sum "$SRV/lane.bin" | awk '{print $1}')
truncate -s 160M "$SRV/norden.bin"; printf 'N' | dd of="$SRV/norden.bin" bs=1 seek=100 conv=notrunc 2>/dev/null
NORDEN_MD5=$(md5sum "$SRV/norden.bin" | awk '{print $1}')
truncate -s 160M "$SRV/wrong.bin"; printf 'W' | dd of="$SRV/wrong.bin" bs=1 seek=100 conv=notrunc 2>/dev/null

# --- the stand-ins for curl: R2, the lane and Norden by URL, speaking curl's -f / -o / -w; every call is logged.
curl() {
    local a
    CF=0; CO=""; CD=""; CW=""; CURL_URL=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -o) CO=$2; shift ;; -d) CD=$2; shift ;; -w) CW=$2; shift ;; -X|-H|--max-time) shift ;;
            --*) ;; -*f*) CF=1 ;; -*) ;; *) CURL_URL=$1 ;;
        esac
        shift
    done
    echo "$CURL_URL $CD" >> "$CALLS"
    case "$CURL_URL" in
        https://r2.test/primal-voice-linux-tool/latest.json)
            [ "$FAKE_R2" = down ] && { reply 000; return; }; reply 200 "$(cat "$SRV/manifest.json")" ;;
        https://r2.test/tool/T1/*)
            [ "$FAKE_R2" = down ] && { reply 000; return; }; reply 200 "" "$SRV/${CURL_URL##*/}" ;;
        https://lane.test/commands/binary/check)
            a=${FAKE_LANE:-update_available}
            case "$a" in
                down) reply 000 ;;
                same) reply 200 "{\"status\":\"up_to_date\",\"modded_hash\":\"$LANE_MD5\",\"expected_modded_hash\":\"$LANE_MD5\",\"download_url\":null}" ;;
                other) reply 200 '{"status":"update_available","modded_hash":"0123456789abcdef0123456789abcdef","expected_modded_hash":"0123456789abcdef0123456789abcdef","download_url":"/commands/binary/download/linux/0123456789abcdef0123456789abcdef"}' ;;
                update_available) reply 200 "{\"status\":\"update_available\",\"modded_hash\":\"$LANE_MD5\",\"expected_modded_hash\":\"$LANE_MD5\",\"download_url\":\"/commands/binary/download/linux/$LANE_MD5\"}" ;;
                *) reply 200 "{\"status\":\"$a\",\"modded_hash\":null,\"expected_modded_hash\":null,\"download_url\":null}" ;;
            esac ;;
        https://lane.test/commands/binary/download/*)
            [ "${FAKE_LANE_DL:-}" = wrong ] && { reply 200 "" "$SRV/wrong.bin"; return; }
            reply 200 "" "$SRV/lane.bin" ;;
        https://manage.norden.cloud/*)
            case "${FAKE_NORDEN:-down}" in
                bin) reply 200 "" "$SRV/norden.bin" ;;
                small) reply 200 "tiny" ;;
                same) reply 204 "" ;;
                *) reply 000 ;;
            esac ;;
        *) reply 000 ;;
    esac
}
reply() { # $1 = HTTP code (000 = unreachable), $2 = body, $3 = a file sent as the body instead
    if [ "$1" = 000 ]; then
        [ -n "$CW" ] && printf '%b' "${CW//'%{http_code}'/000}"
        [ "$CF" = 1 ] && return 22; return 7
    fi
    if [ -n "$CO" ]; then
        if [ -n "${3:-}" ]; then cp --sparse=always "$3" "$CO"; else printf '%s' "$2" > "$CO"; fi
    else
        printf '%s' "$2"
    fi
    [ -n "$CW" ] && printf '%b' "${CW//'%{http_code}'/$1}"
    return 0
}
mv() {
    case "$*" in
        *patched.bin*) [ "${FAKE_MV:-}" = lie ] && return 0 ;;
        *primal_mod_download*|*mod_download.bin*) case "${FAKE_LANE_MV:-}" in fail) return 1 ;; lie) return 0 ;; esac ;;
        *response.bin*) case "${FAKE_NORDEN_MV:-}" in fail) return 1 ;; lie) return 0 ;; esac ;;
    esac
    command mv "$@"
}
sleep() { :; }
log()  { echo "[primal] $*"; }
warn() { echo "[primal] WARN: $*"; }
get_file_hash() { [ -f "$1" ] && md5sum "$1" | awk '{print $1}' || echo ""; }

# A PATH with every tool the step uses except python3.
NOPY="$WORK/nopy"; mkdir -p "$NOPY"
for c in awk cat chmod cp cut date dirname find grep head md5sum mkdir mv rm sed sha256sum stat tail tr; do
    ln -s "$(type -P "$c")" "$NOPY/$c"
done

# new_root <site byte as hex> -> a fresh server root holding a 4 KiB stand-in binary
new_root() {
    R="$WORK/r$RANDOM$RANDOM"; mkdir -p "$R/TheIsle/Binaries/Linux"
    B="$R/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping"
    { printf '\177ELF'; head -c 12 /dev/zero; printf "\\x$1"; head -c 4079 /dev/zero | tr '\0' 'x'; } > "$B"
    chmod 755 "$B"; ORIG=$(get_file_hash "$B")
}
# boot <surv|dm> [NAME=VALUE ...] -> OUT, RC, CALLS, the binary's md5 / byte 16, call counts
boot() {
    local img=$1; shift
    CALLS="$R/calls.log"; : > "$CALLS"
    OUT=$(
        cd "$R" || exit 1
        PRIMAL_PATCHER_MANIFEST=https://r2.test/primal-voice-linux-tool/latest.json
        PRIMAL_BINARY_BASE=https://lane.test; API_KEY=""; MODDED_BINARY=1; MOD_REQUIRED=1; EXPECTED_MODDED_HASH=""
        FAKE_R2=""; FAKE_LANE=""; FAKE_PATCHER=""; FAKE_MV=""; FAKE_LANE_MV=""; FAKE_LANE_DL=""; FAKE_NORDEN=""; FAKE_NORDEN_MV=""
        for kv in "$@"; do eval "$kv"; done
        export FAKE_PATCHER CALLS
        eval "$(block_of "$SURV" | sed "s#/home/container#$R#g")"
        GAME_BINARY=$B; MOD_FILE_PATH=$B; VANILLA_HASH=$(get_file_hash "$B")
        eval "$(step_of "$img" | sed "s#/home/container#$R#g")" 2>&1
        echo "MOD_READY=${MOD_READY:-} MOD_DOWNLOADED=${MOD_DOWNLOADED:-}"
    ) 2>&1
    RC=$?
    BIN_MD5=$(get_file_hash "$B"); SITE=$(od -An -tx1 -j16 -N1 "$B" | tr -d ' ')
    CHECKS=$(grep -c '^https://lane.test/commands/binary/check' "$CALLS")
    DOWNLOADS=$(grep -c '^https://lane.test/commands/binary/download' "$CALLS")
    NORDEN=$(grep -c '^https://manage.norden.cloud' "$CALLS")
}
said() { grep -qF -- "$1" <<<"$OUT"; }
ready() { said "MOD_READY=true" || said "MOD_DOWNLOADED=true"; }
leftovers() { [ ! -e "$R/.primal_mod_download" ] && [ ! -e "$R/mod_download.bin" ] && [ ! -e "$R/response.bin" ] && [ ! -e "$R/_primal/patcher/patched.bin" ]; }

for IMG in surv dm; do
    case $IMG in surv) N=evrima-survival ;; dm) N=deathmatch ;; esac

    echo "$N A - stock binary: patched in place, the lane only cross-checked"
    new_root 74; boot $IMG FAKE_LANE=same
    t "$N A: ready" 'ready' "$(tail -n4 <<<"$OUT")"
    t "$N A: site patched" '[ "$SITE" = eb ]'
    t "$N A: said so, tool named" 'said "binary: PATCHED LOCALLY (tool vT1): ${ORIG:0:16} -> ${BIN_MD5:0:16} (gate=patched@0x10)"'
    t "$N A: lane agrees, asked once, nothing downloaded" '[ $CHECKS = 1 ] && [ $DOWNLOADS = 0 ] && said "the same bytes"'
    t "$N A: no Norden call" '[ $NORDEN = 0 ]'
    t "$N A: patcher, spec and manifest kept" '[ -f "$R/_primal/patcher/patch_worker.py" ] && [ -f "$R/_primal/patcher/patches_linux.json" ] && [ -f "$R/_primal/patcher/manifest.json" ]'
    t "$N A: mode kept, nothing left behind" '[ "$(stat -c%a "$B")" = 755 ] && leftovers'
    KEPT=$R; PATCHED=$BIN_MD5; INODE=$(stat -c%i "$B")

    echo "$N B - the next boot on a patched binary writes nothing and asks the lane nothing"
    boot $IMG
    t "$N B: ready, said already patched" 'ready && said "binary: already patched (${PATCHED:0:16})"'
    t "$N B: same bytes, same file" '[ "$BIN_MD5" = "$PATCHED" ] && [ "$(stat -c%i "$B")" = "$INODE" ]'
    t "$N B: no lane or Norden call" '[ $CHECKS = 0 ] && [ $DOWNLOADS = 0 ] && [ $NORDEN = 0 ]'

    echo "$N C - R2 unreachable: the kept patcher patches; the lane being down does not matter"
    new_root 74; mkdir -p "$R/_primal"; cp -r "$KEPT/_primal/patcher" "$R/_primal/"
    boot $IMG FAKE_R2=down FAKE_LANE=down
    t "$N C: ready on the kept copy" 'ready && [ "$SITE" = eb ] && said "patching with the copy kept from an earlier boot (tool vT1)"'
    t "$N C: said the lane did not answer, nothing downloaded" 'said "did not answer the cross-check" && [ $DOWNLOADS = 0 ]'

    echo "$N D - the lane disagrees: boot the local patch, say it loudly"
    new_root 74; boot $IMG FAKE_LANE=other
    t "$N D: ready on the local patch" 'ready && [ "$SITE" = eb ] && [ $DOWNLOADS = 0 ] && said "the two paths disagree"'

    fallback() { # $1 = label, $2 = the reason the log must name
        WHY=$2
        t "$1: said LOCAL PATCH NOT APPLIED with the reason" 'said "binary: LOCAL PATCH NOT APPLIED - " && said "$WHY"' "$(grep 'LOCAL PATCH' <<<"$OUT")"
        t "$1: the lane binary installed, read back" 'ready && [ "$BIN_MD5" = "$LANE_MD5" ] && [ $DOWNLOADS = 1 ] && said "read back from the binary'"'"'s path"' "$(tail -n3 <<<"$OUT")"
        t "$1: no Norden call, nothing left behind" '[ $NORDEN = 0 ] && leftovers'
    }
    echo "$N E - no python3 in the image: the lane, said by name"
    new_root 74; boot $IMG 'PATH=$NOPY'
    fallback "$N E" "python3 is not in this server's image"
    echo "$N F - R2 unreachable and nothing kept: the lane"
    new_root 74; boot $IMG FAKE_R2=down
    fallback "$N F" 'the tool manifest is unreachable and no copy is kept (https://r2.test/primal-voice-linux-tool/latest.json)'
    echo "$N G - a kept patcher that no longer matches its manifest is not run"
    new_root 74; mkdir -p "$R/_primal"; cp -r "$KEPT/_primal/patcher" "$R/_primal/"; echo '# edited' >> "$R/_primal/patcher/patch_worker.py"
    boot $IMG FAKE_R2=down
    fallback "$N G" 'the kept patch_worker.py does not match its manifest'
    echo "$N H - a download that fails its sha256 is not placed"
    new_root 74; manifest "$GOOD_PW" "$(printf 'f%.0s' $(seq 64))"; boot $IMG
    fallback "$N H" 'patches_linux.json failed its sha256 check'
    t "$N H: nothing placed or staged" '[ ! -e "$R/_primal/patcher/patch_worker.py" ] && [ ! -e "$R/_primal/patcher/stage" ] && [ ! -e "$R/_primal/patcher/manifest.json" ]'
    manifest "$GOOD_PW" ""; new_root 74; boot $IMG
    fallback "$N H2" 'the tool manifest has no valid entry for patches_linux.json'
    manifest "$GOOD_PW" "$GOOD_SPEC"
    echo "$N J/K/L/M - the patcher's word is not the verdict"
    new_root 74; boot $IMG FAKE_PATCHER=lie;   fallback "$N J exit 0, success false" 'the patcher (tool vT1) did not patch this build: exit 0, gate=patched@0x10'
    new_root 74; boot $IMG FAKE_PATCHER=noout; fallback "$N K no output" 'the patcher (tool vT1) did not patch this build: exit 0'
    new_root 74; boot $IMG FAKE_PATCHER=short; fallback "$N L short output" "the patcher's output is not the binary's size"
    new_root 74; boot $IMG FAKE_PATCHER=crash; fallback "$N M crash" 'did not patch this build: exit 1, no report: Traceback (most recent call last): TypeError: unsupported operand'
    echo "$N N - a patched binary whose move does not land is caught by reading it back"
    new_root 74; boot $IMG FAKE_MV=lie
    fallback "$N N" 'the installed binary does not read back as the patcher'"'"'s output'

    echo "$N R - the lane's download is not moved into place: never called installed (#3875)"
    for mode in fail lie; do
        new_root 74; boot $IMG 'PATH=$NOPY' FAKE_LANE_MV=$mode
        t "$N R/$mode: not ready, never said installed" '! ready && ! said "Modded binary installed" && ! said "Mod binary downloaded from backend"' "$(tail -n3 <<<"$OUT")"
        t "$N R/$mode: said it did not land" 'said "the download ${LANE_MD5:0:16} did not land: the binary reads back as ${ORIG:0:16}"'
        t "$N R/$mode: binary untouched, nothing left behind" '[ "$BIN_MD5" = "$ORIG" ] && leftovers'
    done

    echo "$N S - a lane download whose md5 is not the lane's expected hash is not installed"
    new_root 74; boot $IMG 'PATH=$NOPY' FAKE_LANE_DL=wrong
    t "$N S: not installed, binary untouched" '! ready && [ "$BIN_MD5" = "$ORIG" ] && leftovers' "$(tail -n3 <<<"$OUT")"
done

echo "evrima-survival T - how it gives up names both reasons"
new_root 74; boot surv 'PATH=$NOPY' FAKE_LANE_MV=fail
t 'surv T: five attempts, then exit 0 naming the local patch and the lane' '[ $DOWNLOADS = 5 ] && said "Mod is required but not available (local patch: python3 is not in this server'"'"'s image; lane: the download ${LANE_MD5:0:16} did not land" && ! said "MOD_READY="' "$(tail -n2 <<<"$OUT")"
new_root 74; boot surv 'PATH=$NOPY' FAKE_LANE=vanilla_unknown
t 'surv T: vanilla_unknown is the lane having none - asked once, not retried' '[ $CHECKS = 1 ] && said "the lane has no modded binary for vanilla ${ORIG:0:16} (vanilla_unknown)" && ! said "unexpected status"'
t 'surv T: ...and the exit names the local reason' 'said "Mod is required but not available (local patch: python3 is not in this server'"'"'s image). Exiting"'
new_root 74; boot surv 'PATH=$NOPY' FAKE_LANE=vanilla_unknown MOD_REQUIRED=0
t 'surv T: MOD_REQUIRED=0 continues and says why' 'said "continuing WITHOUT verified modded binary (MOD_REQUIRED=0; local patch: python3 is not in this server'"'"'s image)" && [ "$BIN_MD5" = "$ORIG" ]'
new_root 74; boot surv MODDED_BINARY=0
t 'surv T: MODDED_BINARY=0 runs neither the patcher nor the lane' '[ "$BIN_MD5" = "$ORIG" ] && [ ! -e "$R/_primal" ] && [ $CHECKS = 0 ]'

echo "deathmatch U - Norden after the lane: read back, and every loop ends"
new_root 74; boot dm 'PATH=$NOPY' FAKE_LANE=down FAKE_NORDEN=bin
t 'dm U: Norden binary installed, read back' 'ready && [ "$BIN_MD5" = "$NORDEN_MD5" ] && said "Mod binary downloaded and updated (167772160 bytes, hash ${NORDEN_MD5:0:16}..., read back from the binary'"'"'s path)" && leftovers'
new_root 74; boot dm 'PATH=$NOPY' FAKE_LANE=down FAKE_NORDEN=bin FAKE_NORDEN_MV=fail
t 'dm U: a Norden binary that does not land is retried 5 times, then the loop ends' '[ $NORDEN = 5 ] && [ "$(grep -c "Norden binary not installed: the download ${NORDEN_MD5:0:16} did not land" <<<"$OUT")" = 5 ] && [ "$BIN_MD5" = "$ORIG" ]' "$NORDEN calls"
new_root 74; boot dm 'PATH=$NOPY' FAKE_LANE=down FAKE_NORDEN=bin FAKE_NORDEN_MV=lie
t 'dm U: a Norden move that reports success but does not land is never called installed' '! ready && ! said "Mod binary downloaded and updated" && [ "$BIN_MD5" = "$ORIG" ] && leftovers' "$(tail -n3 <<<"$OUT")"
new_root 74; boot dm 'PATH=$NOPY' FAKE_LANE=down FAKE_NORDEN=small
t 'dm U: a Norden file too small is retried 5 times, then the loop ends' '[ $NORDEN = 5 ] && [ "$BIN_MD5" = "$ORIG" ]' "$NORDEN calls"
t 'dm U: the boot says no binary was verified, and why' 'said "NO VERIFIED MOD BINARY: the local patch did not run (python3 is not in this server'"'"'s image)" && said "Booting the binary on disk unverified (hash: ${ORIG:0:16}"' "$(tail -n3 <<<"$OUT")"
t 'dm U: ...and never claims an existing mod' '! said "Proceeding with existing mod"'
new_root 74; boot dm 'PATH=$NOPY' FAKE_LANE_MV=fail
t 'dm U: a lane binary that did not land is named in the last line' 'said "(backend: the download ${LANE_MD5:0:16} did not land: the binary reads back as ${ORIG:0:16})"' "$(tail -n3 <<<"$OUT")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
