#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "${REPO_ROOT}/.env"; set +a
fi

# Private key path. SSH_PUBLIC_KEY_PATH is derived from this by appending .pub.
KEY_NAME="${SSH_KEY_NAME:-ghestest_id_ed25519}"
SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH:-${HOME}/.ssh/${KEY_NAME}}"
SSH_PUBLIC_KEY_PATH="${SSH_PUBLIC_KEY_PATH:-${SSH_PRIVATE_KEY_PATH}.pub}"
KEY_COMMENT="${SSH_KEY_COMMENT:-ghestest-admin@$(hostname -s 2>/dev/null || echo localhost)}"

if [[ -f "${SSH_PRIVATE_KEY_PATH}" ]]; then
  echo "[OK] SSH key already exists at ${SSH_PRIVATE_KEY_PATH} — skipping generation"
else
  mkdir -p "$(dirname "${SSH_PRIVATE_KEY_PATH}")"
  ssh-keygen -t ed25519 -f "${SSH_PRIVATE_KEY_PATH}" -N "" -C "${KEY_COMMENT}"
  echo "[OK] Generated ${SSH_PRIVATE_KEY_PATH}"
fi

echo
echo "Public key (${SSH_PUBLIC_KEY_PATH}):"
cat "${SSH_PUBLIC_KEY_PATH}"
echo
echo "scripts/02-deploy.sh reads this key automatically via SSH_PUBLIC_KEY_PATH."
