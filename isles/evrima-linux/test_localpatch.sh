#!/usr/bin/env bash
# Behaviour test for the binary section of start-evrima.sh: the local patch first, the binary lane as
# its fallback (A722 follow-up). Runs the REAL lines lifted from the shipping wrapper with a stand-in
# patcher (same arguments, exit codes and report shape as patch_worker.py), a stand-in R2 and a
# stand-in lane. The real patcher on real game builds is proven in Docker (see the PR).
#   bash isles/evrima-linux/test_localpatch.sh [wrapper]     (default: ./start-evrima.sh beside it)
HERE=$(cd "$(dirname "$0")" && pwd)
WRAPPER=${1:-$HERE/start-evrima.sh}
BLOCK=$(sed -n '/^# LOCAL PATCH, FIRST/,/^# RENDER Game.ini/p' "$WRAPPER" | head -n -2)
[ -n "$BLOCK" ] || { echo "anchor not found in $WRAPPER"; exit 1; }
command -v python3 >/dev/null || { echo "python3 is needed to run the stand-in patcher"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok() { if [ "$2" = 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "  FAIL $1 ${3:-}"; fi; }
t() { if eval "$2"; then ok "$1" 0; else ok "$1" 1 "$3"; fi; }

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

# The lane's modded binary: over the wrapper's 150 MB floor, sparse so it costs no disk.
truncate -s 160M "$SRV/lane.bin"
LANE_MD5=$(md5sum "$SRV/lane.bin" | awk '{print $1}')

# --- the stand-ins for curl: R2 + the lane, by URL; every call is logged.
curl() {
    local out="" data="" url="" a
    while [ $# -gt 0 ]; do
        case "$1" in
            -o) out=$2; shift ;; -d) data=$2; shift ;; -X|-H|--max-time|-w) shift ;;
            -*) ;; *) url=$1 ;;
        esac
        shift
    done
    echo "$url ${data}" >> "$CALLS"
    case "$url" in
        https://r2.test/primal-voice-linux-tool/latest.json|https://r2.test/alt/latest.json)
            [ "$FAKE_R2" = down ] && return 22; cat "$SRV/manifest.json" ;;
        https://r2.test/tool/T1/*)
            [ "$FAKE_R2" = down ] && return 22; cp "$SRV/${url##*/}" "$out" ;;
        https://lane.test/commands/binary/check)
            a=${FAKE_LANE:-update_available}
            [ "$a" = down ] && return 22
            case "$a" in
                same) echo '{"status": "up_to_date"}' ;;
                other) echo '{"status": "update_available", "expected_modded_hash": "0123456789abcdef0123456789abcdef"}' ;;
                *) printf '{"status": "%s", "expected_modded_hash": "%s", "download_url": "/commands/binary/download/linux/%s"}\n' "$a" "$LANE_MD5" "$LANE_MD5" ;;
            esac ;;
        https://lane.test/commands/binary/download/*) cp --sparse=always "$SRV/lane.bin" "$out" ;;
        *) return 22 ;;
    esac
}
mv() {
    case "$*" in
        *.primal_patch_out*) [ "${FAKE_MV:-}" = lie ] && return 0 ;;
        *.primal_mod_download*) case "${FAKE_LANE_MV:-}" in fail) return 1 ;; lie) return 0 ;; esac ;;
    esac
    command mv "$@"
}
sleep() { :; }
log()  { echo "[primal] $*"; }
warn() { echo "[primal] WARN: $*"; }
refuse() { echo "REFUSED $1 :: ${*:2}"; exit 3; }
md5_of() { [ -f "$1" ] && md5sum "$1" | awk '{print $1}' || echo ""; }
sha256_of() { [ -f "$1" ] && sha256sum "$1" | awk '{print $1}' || echo ""; }
env_or() { if [ -n "${1:-}" ]; then echo "$1"; else echo "$2"; fi; }
m_field()  { grep -o "\"$2\" *: *\"[^\"]*\"" <<<"$1" | head -1 | sed 's/.*: *"//; s/"$//'; }
m_fields() { grep -o "\"$2\" *: *\"[^\"]*\"" <<<"$1" | sed 's/.*: *"//; s/"$//'; }

# A PATH with every tool the block uses except python3.
NOPY="$WORK/nopy"; mkdir -p "$NOPY"
for c in awk cat chmod cp cut date find grep head md5sum mkdir mv rm sed sha256sum stat tail tr; do
    ln -s "$(type -P "$c")" "$NOPY/$c"
done

# new_root <site byte as hex> -> a fresh server root holding a 4 KiB stand-in binary
new_root() {
    R="$WORK/r$RANDOM$RANDOM"; mkdir -p "$R/_primal" "$R/TheIsle/Binaries/Linux"
    B="$R/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping"
    { printf '\177ELF'; head -c 12 /dev/zero; printf "\\x$1"; head -c 4079 /dev/zero | tr '\0' 'x'; } > "$B"
    chmod 755 "$B"
}
# boot [NAME=VALUE ...] -> OUT (the block's console), RC, CALLS, plus the binary's md5 / inode / byte 16
boot() {
    CALLS="$R/calls.log"; : > "$CALLS"
    OUT=$(
        cd "$R" || exit 1
        ROOT=$R; PRIM=$R/_primal; GAME_BINARY=$B; R2_BASE=https://r2.test
        PRIMAL_BINARY_BASE=https://lane.test; BINARY_BASE_SOURCE=test; PRIMAL_ALLOW_VANILLA=0
        HAVE_JQ=0; JQ=/nonexistent; PRIMAL_PATCHER_MANIFEST=""
        FAKE_R2=""; FAKE_LANE=""; FAKE_PATCHER=""; FAKE_MV=""; FAKE_LANE_MV=""
        for kv in "$@"; do eval "$kv"; done
        export FAKE_PATCHER CALLS
        VSIZE=$(stat -c%s "$GAME_BINARY"); VANILLA_HASH=$(md5_of "$GAME_BINARY")
        eval "$BLOCK" 2>&1
        echo "MOD_READY=$MOD_READY"
    )
    RC=$?
    BIN_MD5=$(md5_of "$B"); BIN_INODE=$(stat -c%i "$B"); SITE=$(od -An -tx1 -j16 -N1 "$B" | tr -d ' ')
    CHECKS=$(grep -c '^https://lane.test/commands/binary/check' "$CALLS")
    DOWNLOADS=$(grep -c '^https://lane.test/commands/binary/download' "$CALLS")
}
said() { grep -qF -- "$1" <<<"$OUT"; }
ready() { said "MOD_READY=1"; }

manifest "$GOOD_PW" "$GOOD_SPEC"

echo "A - stock binary: patched in place by the local patcher, the lane only cross-checked"
new_root 74
boot FAKE_LANE=same
t 'ready' 'ready' "$OUT"
t 'site patched' '[ "$SITE" = eb ]' "$SITE"
t 'said so' 'said "binary: PATCHED LOCALLY (tool vT1)"'
t 'read the default manifest URL' 'grep -q "^https://r2.test/primal-voice-linux-tool/latest.json" "$CALLS"'
t 'lane agrees, said once' '[ $CHECKS = 1 ] && said "the same bytes"'
t 'no lane download' '[ $DOWNLOADS = 0 ]'
t 'patcher + spec + manifest kept' '[ -f "$R/_primal/patcher/patch_worker.py" ] && [ -f "$R/_primal/patcher/patches_linux.json" ] && [ -f "$R/_primal/patcher/manifest.json" ]'
t 'no output file left' '[ ! -e "$R/.primal_patch_out" ]'
t 'mode kept' '[ "$(stat -c%a "$B")" = 755 ]'
PATCHED_MD5=$BIN_MD5; FIRST_INODE=$BIN_INODE

echo "B - the next boot on a binary already patched writes nothing and asks the lane nothing"
boot
t 'ready' 'ready' "$OUT"
t 'said already patched' 'said "binary: already patched"'
t 'same bytes, same file' '[ "$BIN_MD5" = "$PATCHED_MD5" ] && [ "$BIN_INODE" = "$FIRST_INODE" ]'
t 'no lane call' '[ $CHECKS = 0 ] && [ $DOWNLOADS = 0 ]'

echo "C - R2 unreachable: the kept patcher patches a restaged stock binary"
KEPT_R=$R
new_root 74; cp -r "$KEPT_R/_primal/patcher" "$R/_primal/"
boot FAKE_R2=down FAKE_LANE=down
t 'ready' 'ready' "$OUT"
t 'site patched' '[ "$SITE" = eb ]'
t 'said it used the kept copy' 'said "patching with the copy kept from an earlier boot (tool vT1)"'
t 'the lane being down does not matter' 'said "did not answer the cross-check" && [ $DOWNLOADS = 0 ]'

echo "D - the lane disagrees with the local patch: boot the local patch, say it loudly"
new_root 74
boot FAKE_LANE=other
t 'ready on the local patch' 'ready && [ "$SITE" = eb ] && [ $DOWNLOADS = 0 ]'
t 'said they disagree' 'said "the two paths disagree"'

fallback() { # $1 = label, $2 = the reason the log must name
    WHY=$2
    t "$1: not ready on the local patch" 'said "LOCAL PATCH NOT APPLIED"'
    t "$1: names why" 'said "$WHY"' "$(grep 'LOCAL PATCH NOT APPLIED' <<<"$OUT")"
    t "$1: the lane binary installed" 'ready && [ "$BIN_MD5" = "$LANE_MD5" ] && [ $DOWNLOADS = 1 ]' "$(tail -n3 <<<"$OUT")"
    t "$1: installed = read back" 'said "read back from the binary'"'"'s path"'
}

echo "E - no python3 in the image: the lane, said by name"
new_root 74
boot 'PATH=$NOPY'
fallback 'no python3' 'python3 is not in this server'"'"'s image'

echo "F - R2 unreachable and nothing kept: the lane"
new_root 74
boot FAKE_R2=down
fallback 'no manifest' 'the tool manifest is unreachable and no copy is kept (https://r2.test/primal-voice-linux-tool/latest.json)'

echo "G - a kept patcher that no longer matches its manifest is not run"
new_root 74; cp -r "$KEPT_R/_primal/patcher" "$R/_primal/"; echo '# edited' >> "$R/_primal/patcher/patch_worker.py"
boot FAKE_R2=down
fallback 'tampered kept copy' 'the kept patch_worker.py does not match its manifest'

echo "H - a download that fails its sha256 is not placed, and nothing half-placed"
new_root 74
manifest "$GOOD_PW" "$(printf 'f%.0s' $(seq 64))"
boot
fallback 'sha mismatch' 'patches_linux.json failed its sha256 check'
t 'nothing placed' '[ ! -e "$R/_primal/patcher/patch_worker.py" ] && [ ! -e "$R/_primal/patcher/stage" ] && [ ! -e "$R/_primal/patcher/manifest.json" ]'
manifest "$GOOD_PW" "$GOOD_SPEC"

echo "I - a manifest entry missing its sha256, or with an empty one, is refused"
new_root 74
sed -i '/"patches_linux.json"/ s/"sha256": "[0-9a-f]*", //' "$SRV/manifest.json"
boot
fallback 'misaligned manifest' 'the tool manifest has no valid entry for patch_worker.py'
new_root 74
manifest "$GOOD_PW" ""
boot
fallback 'empty sha256' 'the tool manifest has no valid entry for patches_linux.json'
t 'empty sha: nothing placed or staged' '[ ! -e "$R/_primal/patcher/patch_worker.py" ] && [ ! -e "$R/_primal/patcher/stage" ]'
manifest "$GOOD_PW" "$GOOD_SPEC"

echo "J - the patcher exits 0 but its report says it failed: not believed"
new_root 74
boot FAKE_PATCHER=lie
fallback 'exit 0, success false' 'did not patch this build: exit 0'

echo "K - the patcher says success but wrote no binary: not believed"
new_root 74
boot FAKE_PATCHER=noout
fallback 'no output' 'did not patch this build: exit 0'

echo "L - an output of the wrong size is not installed"
new_root 74
boot FAKE_PATCHER=short
fallback 'short output' "the patcher's output is not the binary's size"

echo "M - the patcher crashes: its last line is in the reason"
new_root 74
boot FAKE_PATCHER=crash
fallback 'crash' 'no report: Traceback (most recent call last): TypeError: unsupported operand'

echo "N - a move that does not land is caught by reading the binary back"
new_root 74
boot FAKE_MV=lie
fallback 'move did not land' 'the installed binary does not read back'

echo "O - a build the patterns do not cover, and the lane has none: refused, vanilla never booted"
new_root 00
ORIG=$(md5_of "$B")
boot FAKE_LANE=no_mod_available
t 'refused as binary_signature_unrecognised, not as the lane' 'said "REFUSED binary_signature_unrecognised :: BINARY-SIGNATURE-UNRECOGNISED"' "$(tail -n2 <<<"$OUT")"
t 'the refusal names the patcher and its report' 'said "the signature patch (tool vT1) does not recognise this game build" && said "see $R/_primal/patcher/last-report.json"'
t 'binary untouched' '[ "$BIN_MD5" = "$ORIG" ]'

echo "O2 - the same new build with the lane down and no cache: still the signature, not the lane"
new_root 00
ORIG=$(md5_of "$B")
boot FAKE_LANE=down
t 'refused as binary_signature_unrecognised' 'said "REFUSED binary_signature_unrecognised"' "$(tail -n2 <<<"$OUT")"
t 'binary untouched' '[ "$BIN_MD5" = "$ORIG" ]'

echo "O3 - a patcher that crashed is not called a signature miss"
new_root 74
boot FAKE_PATCHER=crash FAKE_LANE=no_mod_available
t 'refused as mod_binary_unavailable' 'said "REFUSED mod_binary_unavailable"' "$(tail -n2 <<<"$OUT")"

echo "P - local patch impossible and the lane unreachable with no cache: refused, said why"
new_root 74
ORIG=$(md5_of "$B")
boot 'PATH=$NOPY' FAKE_LANE=down
t 'refused as mod_binary_lane_unreachable' 'said "REFUSED mod_binary_lane_unreachable"' "$(tail -n2 <<<"$OUT")"
t 'the refusal names the local reason' 'said "the local patch did not run (python3 is not in this server"'
t 'binary untouched' '[ "$BIN_MD5" = "$ORIG" ]'

echo "Q - PRIMAL_PATCHER_MANIFEST points the tool lookup elsewhere"
new_root 74
boot PRIMAL_PATCHER_MANIFEST=https://r2.test/alt/latest.json FAKE_LANE=same
t 'read the override, patched' 'grep -q "^https://r2.test/alt/latest.json" "$CALLS" && ready && [ "$SITE" = eb ]'

lane_no_land() { # $1 = label: the lane's download never lands, so it is never called installed (#3875)
    t "$1: not ready" '! ready' "$(tail -n3 <<<"$OUT")"
    t "$1: never said installed" '! said "modded binary installed"'
    t "$1: said it did not land, each attempt" '[ "$(grep -c "WARN: binary: the download ${LANE_MD5:0:16} did not land: the binary reads back as ${ORIG:0:16} - retrying" <<<"$OUT")" = 5 ] && [ $DOWNLOADS = 5 ]' "$(grep -c "did not land" <<<"$OUT") lines, $DOWNLOADS downloads"
    t "$1: refused as a volume problem, both reasons named" 'said "REFUSED mod_binary_unavailable :: MOD-BINARY-UNAVAILABLE: the lane ANSWERED, but its modded binary for vanilla" && said "could not be installed on this volume (the download ${LANE_MD5:0:16} did not land" && said "and the local patch did not run (python3 is not in this server"' "$(tail -n1 <<<"$OUT")"
    t "$1: binary untouched" '[ "$BIN_MD5" = "$ORIG" ]'
    t "$1: no download left behind" '[ ! -e "$R/.primal_mod_download" ]'
}

echo "R - the lane's download is not moved into place (mv fails): never called installed, refused"
new_root 74; ORIG=$(md5_of "$B")
boot 'PATH=$NOPY' FAKE_LANE_MV=fail
lane_no_land 'mv fails'

echo "S - mv reports success but the binary never changed: caught by reading it back"
new_root 74; ORIG=$(md5_of "$B")
boot 'PATH=$NOPY' FAKE_LANE_MV=lie
lane_no_land 'mv lies'

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
