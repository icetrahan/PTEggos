#!/bin/bash
# test_multihome.sh - the wrapper's MULTIHOME_IP block (BUGS #4223), run on its own with `ip` and `curl` stubbed.
# It must bind+advertise an address the container has, advertise-only an address that is the container's egress
# (host SNAT), and do neither when the egress is another address or unreadable.
#
#     bash isles/evrima-linux/test_multihome.sh [path/to/start-evrima.sh]
set -u
WRAPPER="${1:-$(dirname "$0")/start-evrima.sh}"
T="$(mktemp -d "${TMPDIR:-/tmp}/multihome-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { if [ "$2" = "1" ]; then PASS=$((PASS+1)); echo "  [PASS] $1"; else FAIL=$((FAIL+1)); echo "  [FAIL] $1"; echo "$3" | sed 's/^/         /'; fi; }

awk '/^MULTIHOME=\$\(echo/{on=1} on{print} on&&/^fi$/{exit}' "$WRAPPER" >"$T/block.sh"
[ -s "$T/block.sh" ] || { echo "[FAIL] the MULTIHOME block was not found in $WRAPPER"; exit 1; }

mkdir -p "$T/bin"
cat >"$T/bin/ip" <<'EOF'
#!/bin/bash
echo "2: eth0    inet ${FAKE_IF_IP}/16 brd 172.18.255.255 scope global eth0"
EOF
cat >"$T/bin/curl" <<'EOF'
#!/bin/bash
[ -n "${FAKE_EGRESS:-}" ] || exit 7
echo "$FAKE_EGRESS"
EOF
chmod +x "$T/bin/ip" "$T/bin/curl"

# Runs the block and prints "args=<EXTRA_ARGS> eos=<EOS_OVERRIDE_HOST_IP>" then its log lines.
case_run() {
    env -i PATH="$T/bin:/usr/bin:/bin" MULTIHOME_IP="$1" FAKE_IF_IP="$2" FAKE_EGRESS="$3" SERVER_IP="$4" bash -c '
        log()  { echo "[primal] $*"; }
        warn() { echo "[primal] WARN: $*"; }
        EXTRA_ARGS=()
        source "$0"
        echo "args=${EXTRA_ARGS[*]:-} eos=${EOS_OVERRIDE_HOST_IP:-}"' "$T/block.sh" 2>&1
}

out=$(case_run "51.91.234.82" "51.91.234.82" "51.91.234.82" "51.91.234.82")
ok "an address on the interface is bound and advertised" "$(grep -qx 'args=-MULTIHOME=51.91.234.82 eos=51.91.234.82' <<<"$out" && echo 1)" "$out"

out=$(case_run "51.91.234.82" "172.18.0.7" "51.91.234.82" "51.91.234.82")
ok "an address that is the egress (host SNAT) is advertised, not bound" "$(grep -qx 'args= eos=51.91.234.82' <<<"$out" && echo 1)" "$out"
ok "...and says so" "$(grep -q 'is this server.s egress (host SNAT)' <<<"$out" && echo 1)" "$out"

out=$(case_run "51.91.234.82" "172.18.0.7" "37.187.147.212" "51.91.234.82")
ok "egress from another address: neither bound nor advertised" "$(grep -qx 'args= eos=' <<<"$out" && echo 1)" "$out"
ok "...and the warning names the egress it saw and the service" "$(grep -q "egress reads '37.187.147.212'" <<<"$out" && grep -q 'node-egress-snat.sh' <<<"$out" && echo 1)" "$out"

out=$(case_run "51.91.234.82" "172.18.0.7" "" "51.91.234.82")
ok "egress unreadable: neither bound nor advertised, says unreadable" "$(grep -qx 'args= eos=' <<<"$out" && grep -q "egress reads 'unreadable'" <<<"$out" && echo 1)" "$out"

out=$(case_run "" "172.18.0.7" "51.91.234.82" "51.91.234.82")
ok "MULTIHOME_IP unset: nothing set, SERVER_IP is not used" "$(grep -qx 'args= eos=' <<<"$out" && grep -q 'deliberately NOT used' <<<"$out" && echo 1)" "$out"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
