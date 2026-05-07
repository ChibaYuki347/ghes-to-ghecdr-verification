#!/usr/bin/env bash
# Set up an extra Azure Private DNS Zone so that the GHES VM can resolve its
# own public-style hostname (e.g. ghes-lab.chiba-yuki.com) inside the closed
# network. This is required for the GHES Management Console "Test domain
# settings" step to pass when Hostname is configured to the public-style FQDN.
#
# Why this is needed:
#   - GHES validates Hostname by resolving it from inside the VM and connecting
#     back to itself. The default Private DNS Zone (ghestest.internal) covers
#     internal names only; the public-style FQDN is not resolvable inside the
#     VNet by default.
#   - We avoid putting the GHES VM on the public Internet, so we use a Private
#     DNS Zone scoped to the VNet (Azure DNS handles resolution internally).
#
# Usage:
#   ./scripts/05-setup-public-dns.sh
#   ZONE=example.com LABEL=ghes ./scripts/05-setup-public-dns.sh
#
# Idempotent: re-running with the same parameters is safe.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "${REPO_ROOT}/.env"; set +a
fi

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-${SUBSCRIPTION_ID:-}}"
RG_NAME="${RG_NAME:-rg-ghestest-jpe}"
ZONE="${ZONE:-chiba-yuki.com}"
LABEL="${LABEL:-ghes-lab}"
VNET_NAME="${VNET_NAME:-vnet-ghestest}"
GHES_VM_NAME="${GHES_VM_NAME:-vm-ghestest-ghes}"
INCLUDE_WILDCARD="${INCLUDE_WILDCARD:-true}"

if [[ -z "${SUBSCRIPTION_ID}" ]]; then
  echo "[ERROR] AZURE_SUBSCRIPTION_ID is not set. Copy .env.example to .env or export AZURE_SUBSCRIPTION_ID=." >&2
  exit 1
fi

if ! command -v az >/dev/null 2>&1; then
  echo "[ERROR] Azure CLI 'az' was not found." >&2
  exit 1
fi

current_subscription="$(az account show --query id -o tsv 2>/dev/null || true)"
if [[ -z "${current_subscription}" ]]; then
  echo "[ERROR] Azure CLI is not logged in. Run 'az login' and retry." >&2
  exit 1
fi
if [[ "${current_subscription}" != "${SUBSCRIPTION_ID}" ]]; then
  az account set --subscription "${SUBSCRIPTION_ID}"
fi

echo "[INFO] Subscription: ${SUBSCRIPTION_ID}"
echo "[INFO] Resource group: ${RG_NAME}"
echo "[INFO] VNet: ${VNET_NAME}"
echo "[INFO] Zone: ${ZONE}, label: ${LABEL}"

GHES_PRIVATE_IP="$(az vm list-ip-addresses -g "${RG_NAME}" -n "${GHES_VM_NAME}" \
  --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv 2>/dev/null || true)"
if [[ -z "${GHES_PRIVATE_IP}" ]]; then
  echo "[ERROR] Could not resolve GHES VM private IP (vm: ${GHES_VM_NAME}, rg: ${RG_NAME})." >&2
  exit 1
fi
echo "[INFO] GHES VM private IP: ${GHES_PRIVATE_IP}"

# 1. Zone (idempotent)
existing_zone="$(az network private-dns zone show -g "${RG_NAME}" -n "${ZONE}" \
  --query name -o tsv 2>/dev/null || true)"
if [[ -z "${existing_zone}" ]]; then
  echo "[1/4] Creating Private DNS zone: ${ZONE}"
  az network private-dns zone create -g "${RG_NAME}" -n "${ZONE}" -o none
else
  echo "[1/4] Private DNS zone already exists: ${ZONE}"
fi

# 2. VNet link (idempotent)
LINK_NAME="link-${VNET_NAME}"
existing_link="$(az network private-dns link vnet show -g "${RG_NAME}" \
  --zone-name "${ZONE}" --name "${LINK_NAME}" --query name -o tsv 2>/dev/null || true)"
if [[ -z "${existing_link}" ]]; then
  echo "[2/4] Linking zone to VNet: ${VNET_NAME}"
  az network private-dns link vnet create -g "${RG_NAME}" \
    --zone-name "${ZONE}" \
    --name "${LINK_NAME}" \
    --virtual-network "${VNET_NAME}" \
    --registration-enabled false -o none
else
  echo "[2/4] VNet link already exists: ${LINK_NAME}"
fi

# 3. apex record (label.zone -> GHES IP)
echo "[3/4] Upserting A record: ${LABEL}.${ZONE} -> ${GHES_PRIVATE_IP}"
az network private-dns record-set a create -g "${RG_NAME}" \
  --zone-name "${ZONE}" --name "${LABEL}" --ttl 3600 -o none 2>/dev/null || true
# Replace any existing IPs so re-runs converge.
existing_ips="$(az network private-dns record-set a show -g "${RG_NAME}" \
  --zone-name "${ZONE}" --name "${LABEL}" \
  --query "aRecords[].ipv4Address" -o tsv 2>/dev/null || true)"
for ip in ${existing_ips}; do
  if [[ "${ip}" != "${GHES_PRIVATE_IP}" ]]; then
    az network private-dns record-set a remove-record -g "${RG_NAME}" \
      --zone-name "${ZONE}" --record-set-name "${LABEL}" --ipv4-address "${ip}" -o none
  fi
done
if ! grep -q "${GHES_PRIVATE_IP}" <<< "${existing_ips}"; then
  az network private-dns record-set a add-record -g "${RG_NAME}" \
    --zone-name "${ZONE}" --record-set-name "${LABEL}" \
    --ipv4-address "${GHES_PRIVATE_IP}" -o none
fi

# 4. Wildcard record (for Subdomain Isolation in full-production scenarios)
if [[ "${INCLUDE_WILDCARD}" == "true" ]]; then
  echo "[4/4] Upserting wildcard A record: *.${LABEL}.${ZONE} -> ${GHES_PRIVATE_IP}"
  az network private-dns record-set a create -g "${RG_NAME}" \
    --zone-name "${ZONE}" --name "*.${LABEL}" --ttl 3600 -o none 2>/dev/null || true
  existing_wc="$(az network private-dns record-set a show -g "${RG_NAME}" \
    --zone-name "${ZONE}" --name "*.${LABEL}" \
    --query "aRecords[].ipv4Address" -o tsv 2>/dev/null || true)"
  for ip in ${existing_wc}; do
    if [[ "${ip}" != "${GHES_PRIVATE_IP}" ]]; then
      az network private-dns record-set a remove-record -g "${RG_NAME}" \
        --zone-name "${ZONE}" --record-set-name "*.${LABEL}" --ipv4-address "${ip}" -o none
    fi
  done
  if ! grep -q "${GHES_PRIVATE_IP}" <<< "${existing_wc}"; then
    az network private-dns record-set a add-record -g "${RG_NAME}" \
      --zone-name "${ZONE}" --record-set-name "*.${LABEL}" \
      --ipv4-address "${GHES_PRIVATE_IP}" -o none
  fi
else
  echo "[4/4] Skipping wildcard record (INCLUDE_WILDCARD != true)"
fi

echo
echo "[OK] Public-style hostname is now resolvable inside the VNet:"
echo "      ${LABEL}.${ZONE} -> ${GHES_PRIVATE_IP}"
if [[ "${INCLUDE_WILDCARD}" == "true" ]]; then
  echo "      *.${LABEL}.${ZONE} -> ${GHES_PRIVATE_IP}"
fi
echo
echo "Next:"
echo "  1. In the GHES setup wizard, set Hostname = ${LABEL}.${ZONE} and click 'Test domain settings'."
echo "  2. Once green, click 'Save and Continue' and let the reconfigure run finish."
