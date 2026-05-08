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

# --- WSL + Microsoft Entra Global Secure Access (GSA) loopback fix ---------
# When the GSA Windows client is running, it installs a 'loopback0' interface
# inside WSL2 and a high-priority routing rule (priority 1) that hijacks ALL
# loopback (127.0.0.0/8) traffic, making `connect_ex(127.0.0.1, port)` hang
# in SYN-SENT instead of returning ECONNREFUSED. The Bastion CLI's
# `is_port_open()` pre-check then never returns and the tunnel never binds.
# We add a higher-priority rule (priority 0) that keeps purely-local loopback
# traffic on the kernel's local table, bypassing the GSA hijack.
# See README troubleshooting section for details.
if ip link show loopback0 >/dev/null 2>&1; then
  if ! ip rule show | grep -qE "^0:[[:space:]]+from 127\.0\.0\.0/8 to 127\.0\.0\.0/8 lookup local"; then
    echo "[INFO] Detected Microsoft Entra Global Secure Access loopback0; adding bypass rule (sudo)..."
    if ! sudo -n ip rule add from 127.0.0.0/8 to 127.0.0.0/8 lookup local priority 0 2>/dev/null; then
      echo "[INFO] sudo password required to install loopback bypass rule:"
      sudo ip rule add from 127.0.0.0/8 to 127.0.0.0/8 lookup local priority 0
    fi
    echo "[INFO] Loopback bypass rule installed."
  fi
fi
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: $0 [--ssh] [--admin-shell] [--web] [--auto-start] [--skip-preflight]

Modes:
  (default)        Management Console: GHES :8443 -> localhost:8443
  --web            Web UI / Git HTTPS: GHES :443  -> localhost:8444
  --ssh            Git SSH:            GHES :22   -> localhost:2200
  --admin-shell    GHES admin shell:   GHES :122  -> localhost:2222

Preflight options:
  --auto-start     If GHES VM is deallocated/stopped, start it and wait
                   for it to be running + GHES warmup (~5 min total).
                   Equivalent to AUTO_START=true.
  --skip-preflight Skip VM power-state check entirely.
                   Equivalent to SKIP_PREFLIGHT=true.

Environment overrides:
  SUBSCRIPTION_ID       Azure subscription ID (default: ${SUBSCRIPTION_ID})
  RG_NAME               Resource group name (default: ${RG_NAME})
  GHES_VM_ID            GHES VM resource ID
  BASTION_NAME          Azure Bastion name
  MODE                  mgmt | web | ssh (default: ${MODE})
  LOCAL_PORT            Local tunnel port
  RESOURCE_PORT         Remote port on the GHES VM
  AUTO_START            true  -> auto start VM if deallocated
  SKIP_PREFLIGHT        true  -> skip VM state check
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
    --web|--https)
      MODE="web"
      ;;
    --auto-start)
      AUTO_START=true
      ;;
    --skip-preflight)
      SKIP_PREFLIGHT=true
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

# --- Preflight: verify VM is running before opening tunnel ----------------
# Skipping this and going straight to `az network bastion tunnel` against a
# deallocated VM yields a vague timeout; users misdiagnose it as a tunnel
# bug. Detect explicitly and offer to start the VM.
SKIP_PREFLIGHT="${SKIP_PREFLIGHT:-false}"
AUTO_START="${AUTO_START:-false}"
if [[ "${SKIP_PREFLIGHT}" != "true" ]]; then
  echo "[preflight] Checking GHES VM power state..."
  power_state="$(az vm get-instance-view --ids "${GHES_VM_ID}" \
    --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" \
    -o tsv 2>/dev/null || true)"
  power_state="${power_state#PowerState/}"
  echo "[preflight] GHES VM power state: ${power_state:-unknown}"

  case "${power_state}" in
    running)
      ;;
    deallocated|stopped|"stopped (deallocated)"|"deallocating"|"")
      if [[ "${AUTO_START}" == "true" ]]; then
        echo "[preflight] AUTO_START=true → starting GHES VM..."
        az vm start --ids "${GHES_VM_ID}" --no-wait
        echo "[preflight] Waiting for VM to reach running state..."
        for i in $(seq 1 30); do
          sleep 10
          ps="$(az vm get-instance-view --ids "${GHES_VM_ID}" \
            --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" \
            -o tsv 2>/dev/null || true)"
          ps="${ps#PowerState/}"
          echo "[preflight]   ${i}/30  state=${ps}"
          if [[ "${ps}" == "running" ]]; then
            echo "[preflight] VM is now running. Allowing 90s for GHES service warmup..."
            sleep 90
            break
          fi
        done
      else
        echo "[preflight][ERROR] GHES VM is not running (state=${power_state:-unknown})." >&2
        echo "[preflight] Run with AUTO_START=true to start it automatically, or:" >&2
        echo "             az vm start --ids '${GHES_VM_ID}'" >&2
        exit 3
      fi
      ;;
    starting)
      echo "[preflight] VM is starting; waiting up to 5 min for it to become running..."
      for i in $(seq 1 30); do
        sleep 10
        ps="$(az vm get-instance-view --ids "${GHES_VM_ID}" \
          --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" \
          -o tsv 2>/dev/null || true)"
        ps="${ps#PowerState/}"
        if [[ "${ps}" == "running" ]]; then
          echo "[preflight] VM running. Waiting 90s for GHES warmup..."
          sleep 90
          break
        fi
      done
      ;;
    *)
      echo "[preflight][WARN] Unknown VM power state '${power_state}'. Continuing anyway." >&2
      ;;
  esac
fi
# --------------------------------------------------------------------------

case "${MODE}" in
  mgmt|management|console)
    RESOURCE_PORT="${RESOURCE_PORT:-8443}"
    LOCAL_PORT="${LOCAL_PORT:-8443}"
    echo "Opening Bastion tunnel: localhost:${LOCAL_PORT} -> ${GHES_VM_ID}:${RESOURCE_PORT} (Management Console)"
    echo "In another terminal, browse: https://localhost:${LOCAL_PORT}"
    ;;
  web|https)
    RESOURCE_PORT="${RESOURCE_PORT:-443}"
    # Use 8444 locally to avoid binding to a privileged port (< 1024).
    LOCAL_PORT="${LOCAL_PORT:-8444}"
    echo "Opening Bastion tunnel: localhost:${LOCAL_PORT} -> ${GHES_VM_ID}:${RESOURCE_PORT} (Web UI / Git HTTPS)"
    echo "In another terminal, browse: https://<your-ghes-hostname>:${LOCAL_PORT}"
    echo "Make sure the hostname resolves to 127.0.0.1 in your client's hosts file."
    ;;
  ssh)
    if [[ "${admin_shell_requested}" == true ]]; then
      RESOURCE_PORT="${SSH_RESOURCE_PORT:-122}"
      # GHES admin shell is at remote port 122. Use 2222 locally to avoid
      # needing root for binding to a privileged port (< 1024).
      LOCAL_PORT="${LOCAL_PORT:-2222}"
    else
      RESOURCE_PORT="${SSH_RESOURCE_PORT:-${RESOURCE_PORT:-22}}"
      # Default to a non-privileged local port (2200) to avoid root requirement.
      LOCAL_PORT="${LOCAL_PORT:-2200}"
    fi
    echo "Opening Bastion tunnel: localhost:${LOCAL_PORT} -> ${GHES_VM_ID}:${RESOURCE_PORT} (SSH)"
    echo "In another terminal, connect with: ssh -p ${LOCAL_PORT} <username>@localhost"
    ;;
  *)
    echo "[ERROR] Unsupported MODE '${MODE}'. Use MODE=mgmt | web | ssh." >&2
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
