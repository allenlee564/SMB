#!/usr/bin/env bash
set -euo pipefail

MODEL=qwen2.5:3b
MANAGEMENT_IP=""
INTERFACE=""
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh [--management-ip IPv4] [--interface NAME]

New installations always keep auto_block=false. If the management IP cannot
be detected, the installer does not guess it and prints a warning.
EOF
}
die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }
valid_ipv4() { python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$1" 2>/dev/null; }

while (($#)); do
  case "$1" in
    --management-ip) [[ $# -ge 2 ]] || die "--management-ip requires a value"; MANAGEMENT_IP=$2; shift 2 ;;
    --interface) [[ $# -ge 2 ]] || die "--interface requires a value"; INTERFACE=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run this installer with sudo"
command -v python3 >/dev/null || die "python3 is required to validate arguments"

if [[ -n $MANAGEMENT_IP ]]; then
  valid_ipv4 "$MANAGEMENT_IP" || die "invalid management IPv4: $MANAGEMENT_IP"
else
  connection=${SSH_CONNECTION:-${SSH_CLIENT:-}}
  candidate=${connection%% *}
  if [[ -n $candidate ]] && valid_ipv4 "$candidate"; then
    MANAGEMENT_IP=$candidate
    echo "Detected management IP from SSH session: $MANAGEMENT_IP"
  fi
fi

if [[ -z $INTERFACE ]]; then
  INTERFACE=$(ip -o route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
  [[ -n $INTERFACE ]] || die "could not detect interface from the default route; use --interface"
  echo "Detected interface from default route: $INTERFACE"
fi
ip link show dev "$INTERFACE" >/dev/null 2>&1 || die "interface does not exist: $INTERFACE"

echo "[1/9] Installing system dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl jq python3 tcpdump iptables iproute2 libcap2-bin

echo "[2/9] Installing Ollama when needed"
if ! command -v ollama >/dev/null 2>&1; then
  curl -fsSL https://ollama.com/install.sh | sh
fi
systemctl enable --now ollama.service

echo "[3/9] Pulling $MODEL"
ollama pull "$MODEL"

echo "[4/9] Creating service account and directories"
id blueai >/dev/null 2>&1 || useradd --system --home /opt/blue-ai --shell /usr/sbin/nologin blueai
install -d -o root -g root -m 0755 /opt/blue-ai/{app,config,tests}
install -d -o blueai -g blueai -m 0750 /opt/blue-ai/{events,logs,state}
touch /opt/blue-ai/state/{blocked_ips.txt,whitelist.txt}
chown blueai:blueai /opt/blue-ai/state/{blocked_ips.txt,whitelist.txt}
chmod 0640 /opt/blue-ai/state/{blocked_ips.txt,whitelist.txt}

echo "[5/9] Installing application and configuration"
install -o root -g root -m 0755 "$SCRIPT_DIR/app/analyzer.py" "$SCRIPT_DIR/app/ddos_detector.py" /opt/blue-ai/app/
install -o root -g root -m 0755 "$SCRIPT_DIR/tests/classification_test.py" "$SCRIPT_DIR/tests/smoke_test.sh" /opt/blue-ai/tests/
if [[ ! -e /opt/blue-ai/config/settings.json ]]; then
  install -o root -g blueai -m 0640 "$SCRIPT_DIR/config/settings.example.json" /opt/blue-ai/config/settings.json
else
  # Installation and upgrades never enable automatic blocking.
  jq '.auto_block = false' /opt/blue-ai/config/settings.json >/opt/blue-ai/config/settings.json.tmp
  mv /opt/blue-ai/config/settings.json.tmp /opt/blue-ai/config/settings.json
  chown root:blueai /opt/blue-ai/config/settings.json; chmod 0640 /opt/blue-ai/config/settings.json
fi
jq --arg interface "$INTERFACE" '.interface = $interface' "$SCRIPT_DIR/config/ddos_detector.example.json" \
  >/opt/blue-ai/config/ddos_detector.json
chown root:blueai /opt/blue-ai/config/ddos_detector.json; chmod 0640 /opt/blue-ai/config/ddos_detector.json

echo "[6/9] Installing firewall commands and whitelist"
install -o root -g root -m 0755 "$SCRIPT_DIR/bin/blueai-ipctl" "$SCRIPT_DIR/bin/blueai-autoblock" /usr/local/sbin/
grep -Fqx '127.0.0.1/32' /opt/blue-ai/state/whitelist.txt || echo '127.0.0.1/32' >>/opt/blue-ai/state/whitelist.txt
if [[ -n $MANAGEMENT_IP ]]; then
  /usr/local/sbin/blueai-ipctl whitelist add "$MANAGEMENT_IP/32"
  if grep -Fqx -- "$MANAGEMENT_IP" /opt/blue-ai/state/blocked_ips.txt; then
    warn "management IP existed in the old blocked list; removing its rules"
    /usr/local/sbin/blueai-ipctl unblock "$MANAGEMENT_IP"
  fi
else
  warn "management IP was not provided or detected; no address was guessed"
  warn "auto_block remains false. Re-run with --management-ip before acceptance"
fi

echo "[7/9] Installing least-privilege policy and services"
install -o root -g root -m 0440 "$SCRIPT_DIR/sudoers/blueai" /etc/sudoers.d/blueai
visudo -cf /etc/sudoers.d/blueai >/dev/null
install -o root -g root -m 0644 "$SCRIPT_DIR/systemd/"*.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable blueai-firewall-restore.service blueai-ddos-detector.service

echo "[8/9] Restoring firewall state and starting detector"
systemctl restart blueai-firewall-restore.service
systemctl restart blueai-ddos-detector.service

echo "[9/9] Running safe smoke test"
/opt/blue-ai/tests/smoke_test.sh /opt/blue-ai

echo "Blue AI v0.2 installed. auto_block=false; enable it only after manual acceptance."
