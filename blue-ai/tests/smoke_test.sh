#!/usr/bin/env bash
set -uo pipefail

ROOT=${1:-/opt/blue-ai}
failures=0
pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1" >&2; failures=$((failures + 1)); }
check() { local label=$1; shift; if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi; }

check "Python syntax" python3 -m py_compile "$ROOT/app/analyzer.py" "$ROOT/app/ddos_detector.py"
check "settings JSON" python3 -m json.tool "$ROOT/config/settings.json"
check "detector JSON" python3 -m json.tool "$ROOT/config/ddos_detector.json"
check "classification tests" python3 "$ROOT/tests/classification_test.py"
check "tcpdump available" command -v tcpdump
check "configured interface exists" bash -c 'ip link show "$(python3 -c '\''import json,sys; print(json.load(open(sys.argv[1]))["interface"])'\'' "$1/config/ddos_detector.json")"' _ "$ROOT"
check "INPUT chain exists" iptables -nL INPUT

if iptables -nL DOCKER-USER >/dev/null 2>&1; then pass "DOCKER-USER chain exists"; else printf '[WARN] DOCKER-USER is absent (Docker may not be running)\n'; fi
if systemctl is-active --quiet ollama; then pass "Ollama service active"; else printf '[WARN] Ollama service is not active\n'; fi
if systemctl is-active --quiet blueai-ddos-detector; then pass "detector service active"; else printf '[WARN] detector service is not active\n'; fi

if python3 - "$ROOT/config/settings.json" <<'PY'
import json, sys
raise SystemExit(0 if json.load(open(sys.argv[1]))["auto_block"] is False else 1)
PY
then pass "auto_block remains disabled"; else fail "auto_block must be false for initial acceptance"; fi

whitelist="$ROOT/state/whitelist.txt"
if [[ -s $whitelist ]] && grep -Fqx '127.0.0.1/32' "$whitelist"; then pass "whitelist is initialized"; else fail "whitelist is missing loopback"; fi
printf 'Smoke test is read-only: it generated no traffic and changed no firewall rules.\n'
exit "$failures"
