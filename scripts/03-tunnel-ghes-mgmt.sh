#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "${REPO_ROOT}/.env"; set +a
fi

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-${SUBSCRIPTION_ID:-}}"
RG_NAME="${RG_NAME:-rg-ghestest-jpe}"
MODE="${MODE:-mgmt}"
GHES_VM_NAME="${GHES_VM_NAME:-vm-ghestest-ghes}"

if [[ -z "${SUBSCRIPTION_ID}" ]]; then
  echo "[ERROR] AZURE_SUBSCRIPTION_ID is not set. Copy .env.example to .env or export AZURE_SUBSCRIPTION_ID=." >&2
  exit 1
fi

usage() {
  cat <<EOF
Usage: $0 [--ssh] [--admin-shell]

Environment overrides:
  SUBSCRIPTION_ID       Azure subscription ID (default: ${SUBSCRIPTION_ID})
  RG_NAME               Resource group name (default: ${RG_NAME})
  GHES_VM_ID            GHES VM resource ID
  BASTION_NAME          Azure Bastion name
  MODE                  mgmt or ssh (default: ${MODE})
  LOCAL_PORT            Local tunnel port
  SSH_RESOURCE_PORT     SSH resource port; use 122 for GHES admin shell
EOF
}

admin_shell_requested=false
for arg in "$@"; do
  case "${arg}" in
    --ssh)
      MODE="ssh"
      ;;
    --admin-shell|--admin)
      MODE="ssh"
      admin_shell_requested=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: ${arg}" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v az >/dev/null 2>&1; then
  echo "[ERROR] Azure CLI 'az' was not found. Install it from: https://learn.microsoft.com/cli/azure/install-azure-cli" >&2
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

latest_deployment_name="$(az deployment sub list --query "[?starts_with(name, 'ghestest-') && properties.provisioningState=='Succeeded'] | sort_by(@, &properties.timestamp)[-1].name" -o tsv 2>/dev/null || true)"
if [[ "${latest_deployment_name}" == "None" ]]; then
  latest_deployment_name=""
fi

if [[ -n "${latest_deployment_name}" ]]; then
  if [[ -z "${GHES_VM_ID:-}" ]]; then
    GHES_VM_ID="$(az deployment sub show --name "${latest_deployment_name}" --query "properties.outputs.ghesVmId.value" -o tsv 2>/dev/null || true)"
  fi
  if [[ -z "${BASTION_NAME:-}" ]]; then
    BASTION_NAME="$(az deployment sub show --name "${latest_deployment_name}" --query "properties.outputs.bastionName.value" -o tsv 2>/dev/null || true)"
  fi
  if [[ "${RG_NAME}" == "rg-ghestest-jpe" ]]; then
    deployment_rg="$(az deployment sub show --name "${latest_deployment_name}" --query "properties.outputs.resourceGroupName.value" -o tsv 2>/dev/null || true)"
    if [[ -n "${deployment_rg}" && "${deployment_rg}" != "None" ]]; then
      RG_NAME="${deployment_rg}"
    fi
  fi
fi

if [[ -z "${GHES_VM_ID:-}" ]]; then
  GHES_VM_ID="$(az vm show -g "${RG_NAME}" -n "${GHES_VM_NAME}" --query id -o tsv 2>/dev/null || true)"
fi
if [[ -z "${BASTION_NAME:-}" ]]; then
  BASTION_NAME="$(az network bastion list -g "${RG_NAME}" --query "[0].name" -o tsv 2>/dev/null || true)"
fi

if [[ -z "${GHES_VM_ID:-}" ]]; then
  echo "[ERROR] Could not determine GHES VM ID. Set GHES_VM_ID or deploy first." >&2
  exit 1
fi
if [[ -z "${BASTION_NAME:-}" || "${BASTION_NAME}" == "None" ]]; then
  echo "[ERROR] Could not determine Bastion name. Set BASTION_NAME or deploy first." >&2
  exit 1
fi

case "${MODE}" in
  mgmt|management|console)
    RESOURCE_PORT="${RESOURCE_PORT:-8443}"
    LOCAL_PORT="${LOCAL_PORT:-8443}"
    echo "Opening Bastion tunnel: localhost:${LOCAL_PORT} -> ${GHES_VM_ID}:${RESOURCE_PORT} (Management Console)"
    echo "In another terminal, browse: https://localhost:${LOCAL_PORT}"
    ;;
  ssh)
    if [[ "${admin_shell_requested}" == true ]]; then
      RESOURCE_PORT="${SSH_RESOURCE_PORT:-122}"
    else
      RESOURCE_PORT="${SSH_RESOURCE_PORT:-${RESOURCE_PORT:-22}}"
    fi
    LOCAL_PORT="${LOCAL_PORT:-${RESOURCE_PORT}}"
    echo "Opening Bastion tunnel: localhost:${LOCAL_PORT} -> ${GHES_VM_ID}:${RESOURCE_PORT} (SSH)"
    echo "In another terminal, connect to localhost:${LOCAL_PORT} with SSH."
    ;;
  *)
    echo "[ERROR] Unsupported MODE '${MODE}'. Use MODE=mgmt or MODE=ssh." >&2
    exit 2
    ;;
esac

echo "Press Ctrl+C to close the tunnel."
az network bastion tunnel \
  --name "${BASTION_NAME}" \
  --resource-group "${RG_NAME}" \
  --target-resource-id "${GHES_VM_ID}" \
  --resource-port "${RESOURCE_PORT}" \
  --port "${LOCAL_PORT}"
