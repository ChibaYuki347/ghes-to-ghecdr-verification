#!/usr/bin/env bash
# Generate a self-signed wildcard TLS certificate for the GHES test instance.
#
# Usage:
#   ./scripts/04-generate-self-signed-cert.sh [ghes-lab.chiba-yuki.com]
#
# Output:
#   certs/<domain>.crt  - PEM certificate (apex + wildcard SAN)
#   certs/<domain>.key  - PEM private key (RSA 4096)
#
# The certificate is intended for *non-production* lab use only — it is
# self-signed and produces browser warnings. Suitable for the GHES → GHE.com
# migration guide test environment where Subdomain Isolation is OFF.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DOMAIN="${1:-ghes-lab.chiba-yuki.com}"
DAYS="${DAYS:-365}"
OUTDIR="${OUTDIR:-${REPO_ROOT}/certs}"

if ! command -v openssl >/dev/null 2>&1; then
  echo "[ERROR] openssl not found. Install it (e.g. 'sudo apt-get install -y openssl')." >&2
  exit 1
fi

mkdir -p "${OUTDIR}"
chmod 700 "${OUTDIR}"

CONF_FILE="$(mktemp)"
trap 'rm -f "${CONF_FILE}"' EXIT

cat > "${CONF_FILE}" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions     = v3_req
prompt             = no

[req_distinguished_name]
CN = ${DOMAIN}
O  = GHES Lab
C  = JP

[v3_req]
keyUsage         = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @alt_names

[alt_names]
DNS.1 = ${DOMAIN}
DNS.2 = *.${DOMAIN}
EOF

CRT_PATH="${OUTDIR}/${DOMAIN}.crt"
KEY_PATH="${OUTDIR}/${DOMAIN}.key"

echo "[INFO] Generating self-signed wildcard cert for ${DOMAIN} (validity: ${DAYS} days)"

openssl req -x509 -nodes -newkey rsa:4096 \
  -days "${DAYS}" \
  -keyout "${KEY_PATH}" \
  -out "${CRT_PATH}" \
  -config "${CONF_FILE}" \
  -extensions v3_req \
  >/dev/null 2>&1

chmod 600 "${KEY_PATH}"
chmod 644 "${CRT_PATH}"

echo
echo "[OK] Certificate: ${CRT_PATH}"
echo "[OK] Private key: ${KEY_PATH}"
echo
echo "Verify SAN entries:"
openssl x509 -in "${CRT_PATH}" -noout -ext subjectAltName
echo
echo "Next steps:"
echo "  1. Open the GHES Management Console (https://localhost:8443/setup)"
echo "  2. Set Hostname = ${DOMAIN}"
echo "  3. Upload the certificate (${CRT_PATH}) and private key (${KEY_PATH})"
echo "  4. Save settings (GHES will reconfigure ~10 min)"
echo "  5. Add to your client's hosts file: 127.0.0.1 ${DOMAIN}"
echo "  6. Start the web tunnel: ./scripts/03-tunnel-ghes-mgmt.sh --web"
echo "  7. Browse https://${DOMAIN}:8444/  (accept the self-signed warning)"
