#!/bin/bash
# export-status.sh
#
# Collects health and alarm status from a StarlingX Distributed Cloud
# System Controller and copies the result (JSON) to one or more bastion hosts.
#
# Runs inside the container started by the Kubernetes CronJob (see k8s/).
# All settings come from environment variables; no credentials in this file.
#
# Required environment:
#   DC_HOST         System Controller OAM IP or FQDN
#   API_USERNAME    Keystone user used for the API calls
#   API_PASSWORD    Password of that user
#   BASTION_HOSTS   Space-separated list of bastion hosts, e.g. "10.0.0.10 10.0.0.11"
#   DEST_USER       SSH user on the bastion hosts
#
# Optional environment:
#   DEST_DIR        Remote directory            (default: /var/tmp)
#   SSH_KEY         Path to the private key     (default: /etc/exporter/ssh/id_rsa)
#   CA_CERT         CA bundle for the API       (default: unset -> TLS check skipped, see README)
#   OUT_DIR         Local scratch directory     (default: /tmp/status-export)

set -euo pipefail

: "${DC_HOST:?DC_HOST is required}"
: "${API_USERNAME:?API_USERNAME is required}"
: "${API_PASSWORD:?API_PASSWORD is required}"
: "${BASTION_HOSTS:?BASTION_HOSTS is required}"
: "${DEST_USER:?DEST_USER is required}"

DEST_DIR="${DEST_DIR:-/var/tmp}"
SSH_KEY="${SSH_KEY:-/etc/exporter/ssh/id_rsa}"
OUT_DIR="${OUT_DIR:-/tmp/status-export}"

if [ -n "${CA_CERT:-}" ]; then
  CURL_TLS=(--cacert "$CA_CERT")
else
  echo "WARNING: CA_CERT not set, TLS verification is disabled" >&2
  CURL_TLS=(-k)
fi

mkdir -p "$OUT_DIR"
trap 'rm -rf "$OUT_DIR"' EXIT

timestamp="$(date +"%Y-%m-%d_%H-%M")"

# --- 1. Get a Keystone token -------------------------------------------------
payload="$(jq -n --arg u "$API_USERNAME" --arg p "$API_PASSWORD" '{
  auth: {
    identity: { methods: ["password"],
                password: { user: { name: $u, domain: { id: "default" }, password: $p } } },
    scope: { project: { name: "admin", domain: { id: "default" } } }
  }}')"

TOKEN="$(curl -s -i "${CURL_TLS[@]}" \
  -H "Content-Type: application/json" -d "$payload" \
  "https://${DC_HOST}:5000/v3/auth/tokens" \
  | awk 'tolower($1)=="x-subject-token:" {print $2}' | tr -d '\r')"

if [ -z "$TOKEN" ]; then
  echo "ERROR: could not obtain an API token from ${DC_HOST}" >&2
  exit 1
fi

# --- 2. Collect status and alarms --------------------------------------------
api_get() {  # api_get <port> <path> <output-file>
  curl -sf "${CURL_TLS[@]}" -H "Content-Type: application/json" \
    -H "X-Auth-Token: $TOKEN" "https://${DC_HOST}:$1$2" | jq . > "$3"
}

api_get 8119  /v1.0/subclouds "$OUT_DIR/subclouds_status_${timestamp}.json"   # dcmanager: managed clusters
api_get 8119  /v1.0/alarms    "$OUT_DIR/subclouds_alarms_${timestamp}.json"   # dcmanager: alarm summary per cluster
api_get 18002 /v1/alarms      "$OUT_DIR/system_controller_alarms_${timestamp}.json"  # fault management
api_get 6385  /v1/ihosts      "$OUT_DIR/system_controller_hosts_${timestamp}.json"   # sysinv: hosts

# --- 3. Copy to every bastion host --------------------------------------------
mkdir -p ~/.ssh && chmod 700 ~/.ssh
failures=0
for host in $BASTION_HOSTS; do
  ssh-keyscan -H "$host" >> ~/.ssh/known_hosts 2>/dev/null || true
  if scp -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 \
        "$OUT_DIR"/*_"${timestamp}".json "${DEST_USER}@${host}:${DEST_DIR}/"; then
    echo "OK: files copied to ${host}"
  else
    echo "ERROR: copy to ${host} failed" >&2
    failures=$((failures + 1))
  fi
done

# Non-zero exit makes the Kubernetes job fail visibly if any bastion was unreachable.
[ "$failures" -eq 0 ]
