#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "${REPO_ROOT}/.env"; set +a
fi

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-${SUBSCRIPTION_ID:-}}"
LOCATION="${LOCATION:-japaneast}"
RG_NAME="${RG_NAME:-rg-ghestest-jpe}"
SSH_KEY_NAME="${SSH_KEY_NAME:-ghestest_id_ed25519}"
SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH:-${HOME}/.ssh/${SSH_KEY_NAME}}"
SSH_PUBLIC_KEY_PATH="${SSH_PUBLIC_KEY_PATH:-${SSH_PRIVATE_KEY_PATH}.pub}"

if [[ -z "${SUBSCRIPTION_ID}" ]]; then
  echo "[ERROR] AZURE_SUBSCRIPTION_ID is not set." >&2
  echo "  Either: (1) export AZURE_SUBSCRIPTION_ID=<your-sub-id>" >&2
  echo "  Or:     (2) copy .env.example to .env and fill in AZURE_SUBSCRIPTION_ID=..." >&2
  exit 1
fi

RG_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG_NAME}"

RUN_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="${REPO_ROOT}/logs"
LOG_FILE="${LOG_DIR}/deploy-${RUN_TIMESTAMP}.log"
DEPLOYMENT_RESULT_FILE="${LOG_DIR}/deploy-${RUN_TIMESTAMP}.json"

mkdir -p "${LOG_DIR}"

echo_value() {
  local label="$1"
  local value="$2"
  if [[ -n "${value}" && "${value}" != "null" && "${value}" != "None" ]]; then
    echo "${label}: ${value}"
  else
    echo "${label}: <not returned>"
  fi
}

main() {
  echo "[INFO] Writing deployment log to ${LOG_FILE}"

  if ! command -v az >/dev/null 2>&1; then
    echo "[ERROR] Azure CLI 'az' was not found. Install it from: https://learn.microsoft.com/cli/azure/install-azure-cli" >&2
    exit 1
  fi

  local current_subscription
  current_subscription="$(az account show --query id -o tsv 2>/dev/null || true)"
  if [[ -z "${current_subscription}" ]]; then
    echo "[ERROR] Azure CLI is not logged in. Run 'az login' and retry." >&2
    exit 1
  fi

  if [[ "${current_subscription}" != "${SUBSCRIPTION_ID}" ]]; then
    echo "[INFO] Current subscription is ${current_subscription}; switching to ${SUBSCRIPTION_ID}"
    az account set --subscription "${SUBSCRIPTION_ID}"
    current_subscription="$(az account show --query id -o tsv)"
    if [[ "${current_subscription}" != "${SUBSCRIPTION_ID}" ]]; then
      echo "[ERROR] Failed to switch Azure CLI to subscription ${SUBSCRIPTION_ID}. Current: ${current_subscription}" >&2
      exit 1
    fi
  fi
  echo "[OK] Azure subscription: ${SUBSCRIPTION_ID}"

  if [[ ! -f "${SSH_PUBLIC_KEY_PATH}" ]]; then
    echo "[ERROR] SSH public key not found at ${SSH_PUBLIC_KEY_PATH}. Run ./scripts/01-generate-ssh-key.sh first." >&2
    exit 1
  fi
  echo "[OK] SSH public key found: ${SSH_PUBLIC_KEY_PATH}"

  if [[ ! -f infra/main.bicep ]]; then
    echo "[ERROR] Bicep entrypoint not found: infra/main.bicep" >&2
    exit 1
  fi
  if [[ ! -f infra/main.bicepparam ]]; then
    echo "[ERROR] Bicep parameter file not found: infra/main.bicepparam" >&2
    exit 1
  fi
  echo "[OK] Bicep files found"

  echo "[INFO] Resource group ${RG_NAME} will be created/updated by the Bicep deployment (subscription scope)"

  echo "[INFO] Current subscription-level Defender for Servers pricing (informational only):"
  az security pricing show --name VirtualMachines -o table || true
  echo "[NOTE] Per-VM override to Free will be applied AFTER deployment (RG-scope override is not supported by the API)."

  echo "[INFO] Exporting SSH public key to env for Bicep parameter file"
  if [[ ! -f "${SSH_PUBLIC_KEY_PATH}" ]]; then
    echo "[ERROR] SSH public key not found at ${SSH_PUBLIC_KEY_PATH}." >&2
    echo "        Run ./scripts/01-generate-ssh-key.sh first or set SSH_PUBLIC_KEY_PATH in .env." >&2
    exit 1
  fi
  GHES_SSH_PUBLIC_KEY="$(cat "${SSH_PUBLIC_KEY_PATH}")"
  export GHES_SSH_PUBLIC_KEY

  echo "[INFO] Validating Bicep deployment"
  az deployment sub validate \
    --location "${LOCATION}" \
    --template-file infra/main.bicep \
    --parameters infra/main.bicepparam

  local deployment_name="ghestest-$(date +%Y%m%d-%H%M%S)"
  echo "[INFO] Starting deployment ${deployment_name}"
  if ! az deployment sub create \
    --name "${deployment_name}" \
    --location "${LOCATION}" \
    --template-file infra/main.bicep \
    --parameters infra/main.bicepparam \
    -o json >"${DEPLOYMENT_RESULT_FILE}" 2>&1; then
    echo "[ERROR] Deployment ${deployment_name} failed. Last 100 lines from ${DEPLOYMENT_RESULT_FILE}:" >&2
    tail -n 100 "${DEPLOYMENT_RESULT_FILE}" >&2 || true
    exit 1
  fi
  echo "[OK] Deployment result captured at ${DEPLOYMENT_RESULT_FILE}"

  echo "[INFO] Deployment outputs:"
  az deployment sub show --name "${deployment_name}" --query "properties.outputs" -o json

  echo "[INFO] Applying per-VM Defender for Servers Free override (post-deploy)"
  local vm_ids
  vm_ids="$(az vm list -g "${RG_NAME}" --query "[].id" -o tsv)"
  if [[ -z "${vm_ids}" ]]; then
    echo "[WARN] No VMs found in RG ${RG_NAME}; skipping Defender override."
  else
    while IFS= read -r vm_id; do
      [[ -z "${vm_id}" ]] && continue
      local vm_name
      vm_name="$(basename "${vm_id}")"
      echo "[INFO]  - Override Defender to Free on ${vm_name}"
      az rest --method PUT \
        --uri "https://management.azure.com${vm_id}/providers/Microsoft.Security/pricings/virtualMachines?api-version=2024-01-01" \
        --body '{"properties":{"pricingTier":"Free"}}' \
        -o none
    done <<< "${vm_ids}"
    echo "[OK] Per-VM Defender override applied."
  fi

  echo "[INFO] Verifying VM extensions (expect minimal/none after Defender override):"
  while IFS= read -r vm_id; do
    [[ -z "${vm_id}" ]] && continue
    local vm_name
    vm_name="$(basename "${vm_id}")"
    echo "  --- ${vm_name} ---"
    az vm extension list --ids "${vm_id}" --query "[].{name:name, state:provisioningState, type:typePropertiesType}" -o table || true
  done <<< "${vm_ids}"

  local ghes_vm_id
  local ghes_private_ip
  local ghes_fqdn
  local tunnel_command
  ghes_vm_id="$(az deployment sub show --name "${deployment_name}" --query "properties.outputs.ghesVmId.value" -o tsv)"
  ghes_private_ip="$(az deployment sub show --name "${deployment_name}" --query "properties.outputs.ghesPrivateIp.value" -o tsv)"
  ghes_fqdn="$(az deployment sub show --name "${deployment_name}" --query "properties.outputs.ghesFqdn.value" -o tsv)"
  tunnel_command="$(az deployment sub show --name "${deployment_name}" --query "properties.outputs.tunnelCommand.value" -o tsv)"

  echo
  echo "Key outputs:"
  echo_value "GHES VM ID" "${ghes_vm_id}"
  echo_value "GHES Private IP" "${ghes_private_ip}"
  echo_value "GHES FQDN" "${ghes_fqdn}"
  echo_value "tunnelCommand" "${tunnel_command}"

  cat <<EOF

[SUCCESS] Deployment complete.
Next steps:
  1. Open a tunnel:    ./scripts/03-tunnel-ghes-mgmt.sh
  2. Browse GHES:      https://localhost:8443  (initial setup screen — upload license)
  3. Operator SSH:     az network bastion ssh --name ${BASTION_NAME:-<bastion>} --resource-group ${RG_NAME} --target-resource-id ${ghes_vm_id} --auth-type ssh-key --username ghadmin --ssh-key ${SSH_PRIVATE_KEY_PATH}
  4. Tear down:        az group delete -n ${RG_NAME} --yes --no-wait
EOF
}

exec > >(tee "${LOG_FILE}") 2>&1
main "$@"
